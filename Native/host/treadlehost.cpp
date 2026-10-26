// Treadle native host (treadlehost.dll / libtreadlehost.so).
//
// Derived from the native host of the editor Treadle was forked from (NOTICE), Copyright 2026 AproposRobin, licensed under the
// Apache License, Version 2.0 (see NOTICE and FORK-NOTES.md, "Native host"). This comment is
// not compiled into the binaries.
//
// Owns the platform window (SDL2), the GL context, and the Dear ImGui + imnodes
// contexts. Everything else (all UI logic) lives in Beef and talks to ImGui and
// imnodes through cimgui / cimnodes, which are compiled into this same library.
//
// Exposed C API is intentionally tiny: init, begin/end frame, shutdown.

#include "imgui.h"
#include "imgui_impl_sdl2.h"
#include "imgui_impl_opengl3.h"
#include "imgui_internal.h"
#include "imnodes.h"
namespace ImNodes = IMNODES_NAMESPACE;

#include <SDL.h>
#include <SDL_opengl.h>
#include <SDL_syswm.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <deque>
#include <mutex>
#include <set>
#include <string>

#include "treadle_icon.h" // the window icon (packaging/treadle-icon/make-icon-header.ps1)

#if defined(_WIN32)
#include <windows.h>
#include <shobjidl.h>
#include <psapi.h>
#else
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#if defined(_WIN32)
#define TH_API extern "C" __declspec(dllexport)
#else
#define TH_API extern "C" __attribute__((visibility("default")))
#endif

// Assert routing (docs/Architecture.md, "Host asserts"). IM_ASSERT (imconfig.h) and SDL's own
// assertions land in th_assert_failed, which never aborts and never shows a dialog: each distinct
// site (file and line) is reported once per run to the handler the editor registered with
// th_set_assert_handler, or to stderr when none is registered, and the call returns.
typedef void (*ThAssertHandler)(const char* expr, const char* file, int line);
static ThAssertHandler  gAssertHandler = nullptr;
static std::mutex        gAssertMutex;
static std::set<std::string> gAssertSites;

void th_assert_failed(const char* expr, const char* file, int line)
{
	if (file == nullptr)
		file = "?";
	if (expr == nullptr)
		expr = "?";
	{
		std::lock_guard<std::mutex> lock(gAssertMutex);
		if (!gAssertSites.insert(std::string(file) + ":" + std::to_string(line)).second)
			return; // this site already reported in this run
	}
	ThAssertHandler handler = gAssertHandler;
	if (handler != nullptr)
		handler(expr, file, line);
	else
		fprintf(stderr, "treadlehost: [ASSERT] %s at %s:%d\n", expr, file, line);
}

static SDL_AssertState ThSdlAssert(const SDL_AssertData* data, void* userdata)
{
	(void)userdata;
	th_assert_failed(data->condition, data->filename, data->linenum);
	return SDL_ASSERTION_IGNORE;
}

static SDL_Window*   gWindow = nullptr;
static SDL_GLContext gGLContext = nullptr;
static bool          gQuitRequested = false;
// Files dropped onto the window, oldest first (SDL sends one SDL_DROPFILE per file, all in the same
// poll when several are dropped at once). th_poll_drop hands them out one by one; gDropCurrent
// keeps the string it returned alive until the next call.
static std::deque<std::string> gDrops;
static std::string   gDropCurrent;
static const size_t  kMaxQueuedDrops = 4096;
static std::string   gLogPath;   // session log of the editor (th_set_log_path), named in the start-up failure message
static std::string   gLastError; // why the last th_init failed (th_last_error)
// Quiet window (test and capture runs): th_set_window_quiet before th_init; -1 = not called, then
// TREADLE_WINDOW_HIDDEN=1 decides. gQuiet is what th_init used.
static int           gQuietRequest = -1;
static bool          gQuiet = false;

static bool EnvOn(const char* name)
{
	const char* v = getenv(name);
	return v != nullptr && v[0] != 0 && v[0] != '0';
}
static float         gWindowScale = 1.0f; // UI scale (1.0 = 96 dpi) of the display the window is on

// The UI scale of one display. Windows reports the real per-monitor DPI (the process is
// per-monitor DPI aware). Elsewhere SDL only knows the *physical* DPI from the monitor's EDID,
// which says nothing about what the user chose (a 27" 4K panel reads 163 dpi, a bad EDID reads
// 25 or 400), so only TREADLE_UI_SCALE / GDK_SCALE count there; the framebuffer scale of a Retina
// display is ImGui's DisplayFramebufferScale, not a font scale.
static float DisplayScale(int displayIndex)
{
	float scale = 1.0f;
#if defined(_WIN32)
	float ddpi = 0;
	if (displayIndex >= 0 && SDL_GetDisplayDPI(displayIndex, &ddpi, nullptr, nullptr) == 0 && ddpi > 0)
		scale = ddpi / 96.0f;
#else
	(void)displayIndex;
	const char* env = getenv("TREADLE_UI_SCALE");
	if (env == nullptr || atof(env) <= 0)
		env = getenv("GDK_SCALE");
	if (env != nullptr && atof(env) > 0)
		scale = (float)atof(env);
#endif
	if (scale < 1.0f) scale = 1.0f;
	if (scale > 3.0f) scale = 3.0f;
	return scale;
}

static bool FileExists(const char* path)
{
	FILE* f = fopen(path, "rb");
	if (f == nullptr)
		return false;
	fclose(f);
	return true;
}

static void LoadFonts(float scale)
{
	ImGuiIO& io = ImGui::GetIO();
	const char* candidates[] = {
		"C:\\Windows\\Fonts\\segoeui.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
		"/usr/share/fonts/TTF/DejaVuSans.ttf",
		"/System/Library/Fonts/SFNS.ttf",
	};
	for (const char* path : candidates)
	{
		if (FileExists(path))
		{
			if (io.Fonts->AddFontFromFileTTF(path, 16.0f * scale) != nullptr)
				break;
		}
	}
	if (io.Fonts->Fonts.Size == 0)
		io.Fonts->AddFontDefault();

	// Monospace font (index 1) for code panels.
	const char* monoCandidates[] = {
		"C:\\Windows\\Fonts\\consola.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	};
	bool monoLoaded = false;
	for (const char* path : monoCandidates)
	{
		if (FileExists(path) && io.Fonts->AddFontFromFileTTF(path, 15.0f * scale) != nullptr)
		{
			monoLoaded = true;
			break;
		}
	}
	if (!monoLoaded)
		io.Fonts->AddFontDefault();
}

// The imnodes style (graph canvas, node bodies, pins, links). The ImGui style (sizes and colours) is
// not set here: the editor owns it (Look.Apply in TreadleEditor/src/Style.bf), because it re-applies
// the theme on every theme, font size and display-scale change. imnodes has no such owner on the Beef side.
static void ApplyNodeStyle()
{
	ImNodesStyle& ns = ImNodes::GetStyle();
	ImNodes::StyleColorsDark(&ns);
	ns.NodeCornerRounding = 6.0f;
	ns.NodePadding = ImVec2(10, 6);
	ns.NodeBorderThickness = 1.5f;
	ns.LinkThickness = 2.6f;
	ns.LinkLineSegmentsPerLength = 0.12f;
	ns.PinCircleRadius = 5.0f;
	ns.PinTriangleSideLength = 11.0f;
	ns.PinQuadSideLength = 9.0f;
	ns.PinOffset = 0.0f;
	ns.GridSpacing = 16.0f;
	ns.Flags |= ImNodesStyleFlags_GridLinesPrimary | ImNodesStyleFlags_GridSnapping;
	ns.Colors[ImNodesCol_GridBackground]          = IM_COL32(38, 38, 38, 255);
	ns.Colors[ImNodesCol_GridLine]                = IM_COL32(52, 52, 52, 255);
	ns.Colors[ImNodesCol_GridLinePrimary]         = IM_COL32(20, 20, 20, 255);
	ns.Colors[ImNodesCol_NodeBackground]          = IM_COL32(24, 24, 24, 235);
	ns.Colors[ImNodesCol_NodeBackgroundHovered]   = IM_COL32(30, 30, 30, 240);
	ns.Colors[ImNodesCol_NodeBackgroundSelected]  = IM_COL32(30, 30, 30, 245);
	ns.Colors[ImNodesCol_NodeOutline]             = IM_COL32(10, 10, 10, 255);
	ns.Colors[ImNodesCol_Link]                    = IM_COL32(230, 230, 230, 255);
	ns.Colors[ImNodesCol_LinkHovered]             = IM_COL32(255, 255, 255, 255);
	ns.Colors[ImNodesCol_LinkSelected]            = IM_COL32(255, 196, 0, 255);
	ns.Colors[ImNodesCol_BoxSelector]             = IM_COL32(255, 196, 0, 40);
	ns.Colors[ImNodesCol_BoxSelectorOutline]      = IM_COL32(255, 196, 0, 180);
	ns.Colors[ImNodesCol_MiniMapBackground]       = IM_COL32(20, 20, 20, 200);
}

// The editor's handler for host asserts (Beef: ThAssertHandler). Registered before th_init, so
// asserts raised while the window is created are reported too. NULL restores the stderr line.
TH_API void th_set_assert_handler(ThAssertHandler handler)
{
	gAssertHandler = handler;
}

// Tells the host where the editor's session log is, so a start-up failure can name it (th_init shows
// a message box when the window or the graphics context cannot be created). Copied.
TH_API void th_set_log_path(const char* path)
{
	gLogPath = path != nullptr ? path : "";
}

// The reason the last th_init returned 0 (empty before a failure). Valid until the next th_init.
TH_API const char* th_last_error() { return gLastError.c_str(); }

// Releases what th_init made so far (the window, the context, SDL), so a failed start leaves nothing behind.
static void ReleaseWindow()
{
	if (gGLContext != nullptr)
		SDL_GL_DeleteContext(gGLContext);
	gGLContext = nullptr;
	if (gWindow != nullptr)
		SDL_DestroyWindow(gWindow);
	gWindow = nullptr;
	SDL_Quit();
}

// Start-up failure: the window or the graphics context could not be created (no OpenGL 3.0: a remote
// desktop session without GPU acceleration, a virtual machine, the basic display driver). A GUI process has
// no console, so without a message the editor would just not appear. Shows a native message box with the
// reason and the log path (TREADLE_NO_START_DIALOG=1 skips the box, for scripted runs), cleans up, returns 0.
static int InitFail(const char* step)
{
	std::string detail = std::string(step) + ": " + SDL_GetError();
	gLastError = detail;
	fprintf(stderr, "treadlehost: %s\n", detail.c_str());
	ReleaseWindow();
	// A quiet window run (th_set_window_quiet) never shows the box either: it would take the focus.
	if (!gQuiet && !EnvOn("TREADLE_NO_START_DIALOG"))
	{
		std::string text =
			"Treadle could not open its window.\n\n"
			"It needs a graphics driver that supports OpenGL 3.0 or newer. One is"
			"\nusually missing in a remote desktop session without GPU acceleration, in some"
			"\nvirtual machines, and with the basic display driver."
			"\n\nInstall the current driver from the maker of the graphics card, or start"
			"\nTreadle on the computer's own screen."
			"\n\nDetails: " + detail;
		if (!gLogPath.empty())
			text += "\n\nLog file: " + gLogPath;
		SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "Treadle", text.c_str(), nullptr);
	}
	return 0;
}

// Quiet window for test and capture runs, set before th_init: 1 = quiet, 0 = a normal window. Without the
// call, TREADLE_WINDOW_HIDDEN=1 turns it on. The window is created off-screen (beyond the right edge of the
// virtual desktop, at the top of the display it would have opened on), has no taskbar button, is shown
// without being activated and never takes the focus (Windows: WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
// SW_SHOWNOACTIVATE; Linux: SDL's offscreen video driver when it can, else SDL_WINDOW_SKIP_TASKBAR and
// SDL_HINT_WINDOW_NO_ACTIVATION_WHEN_SHOWN);
// th_raise_window does nothing and no start-up message box is shown. It still renders every frame,
// so a capture of its OpenGL back buffer is the same as one of a visible window.
TH_API void th_set_window_quiet(int quiet) { gQuietRequest = quiet != 0 ? 1 : 0; }

// 1 when the window was created in quiet mode.
TH_API int th_window_quiet() { return gQuiet ? 1 : 0; }

// Where a quiet window goes: just beyond the right edge of all displays, at the top of `display`
// (the nearest display stays the same one for its DPI when it is the rightmost; on one monitor it is).
static void QuietPosition(int display, int* x, int* y)
{
	int right = 0;
	int count = SDL_GetNumVideoDisplays();
	for (int d = 0; d < count; d++)
	{
		SDL_Rect r;
		if (SDL_GetDisplayBounds(d, &r) == 0 && r.x + r.w > right)
			right = r.x + r.w;
	}
	SDL_Rect start = { 0, 0, 0, 0 };
	SDL_GetDisplayBounds(display, &start);
	*x = right + 64;
	*y = start.y;
}

#if !defined(_WIN32) && !defined(__APPLE__)
// Linux quiet window: WSLg (and other compositors) ignore a window's off-screen position and map it on the
// screen, so a quiet run uses SDL's offscreen video driver (an EGL pbuffer: no window on any screen, the
// OpenGL back buffer still rendered and readable) when SDL_VIDEODRIVER is not set and that driver can make an
// OpenGL 3.0 context; otherwise it falls back to the off-screen, skip-taskbar window.
static bool UseOffscreenDriver()
{
	if (getenv("SDL_VIDEODRIVER") != nullptr)
		return false;
	SDL_SetHint(SDL_HINT_VIDEODRIVER, "offscreen");
	bool ok = false;
	if (SDL_Init(SDL_INIT_VIDEO) == 0)
	{
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
		SDL_Window* w = SDL_CreateWindow("probe", 0, 0, 64, 64, SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
		if (w != nullptr)
		{
			SDL_GLContext c = SDL_GL_CreateContext(w);
			ok = c != nullptr;
			if (c != nullptr)
				SDL_GL_DeleteContext(c);
			SDL_DestroyWindow(w);
		}
	}
	SDL_Quit(); // clears every hint: the caller sets its own after this
	if (ok)
		SDL_SetHint(SDL_HINT_VIDEODRIVER, "offscreen");
	fprintf(stderr, "treadlehost: quiet window: %s\n", ok ? "offscreen video driver" : "off-screen window (no offscreen OpenGL)");
	return ok;
}
#endif

// ---------------------------------------------------------------- the graphics device (docs/Known-Issues.md)
//
// A laptop switching GPUs, a display driver reset (TDR) after the screen slept or was locked, a monitor or DPI change
// can leave the OpenGL context lost or no longer current: the window frame still answers, its content stays black or
// frozen. The host checks the context every frame (cheap: is it still current, the robustness reset status when the
// context has it, GL_CONTEXT_LOST from glGetError, failed or very slow buffer swaps) and on the window and display
// events that usually come with such a change (a fuller check, logged). When the context is gone it rebuilds the
// drawing side at the start of the next frame: a new context on the same window (a new window at the same place and
// size when that fails), the ImGui renderer objects again (shaders, buffers, the font texture: ImGui re-uploads every
// texture the backend dropped), the swap interval. The editor's documents are not touched; its own textures follow
// th_gl_generation. Three attempts 500 ms apart; after that the window shows a plain message and the frame loop keeps
// running without drawing (autosave and recovery go on), and th_gl_request_restore (Window > Restore Graphics) tries again.

typedef void (*ThLogHandler)(const char* line);
static ThLogHandler gLogHandler = nullptr;

static void GlLog(const char* fmt, ...)
{
	char buf[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (gLogHandler != nullptr)
		gLogHandler(buf);
	else
		fprintf(stderr, "treadlehost: %s\n", buf);
}

// Lines the host writes to the editor's session log ("[gl] ..."). Set before th_init to get the start-up lines.
TH_API void th_set_log_handler(ThLogHandler handler) { gLogHandler = handler; }

enum ThGlCheck
{
	TH_GL_OK = 0,
	TH_GL_NOT_CURRENT = 1,    // the context is no longer current on the frame thread (or was deleted)
	TH_GL_RESET = 2,          // glGetGraphicsResetStatus: the driver reset the device
	TH_GL_CONTEXT_LOST = 3,   // glGetError() == GL_CONTEXT_LOST
	TH_GL_SWAP_FAILED = 4,    // SDL_GL_SwapWindow failed (or took over 2 s) three frames in a row
	TH_GL_NO_RENDERER = 5,    // glGetString(GL_RENDERER) returns nothing
	TH_GL_DEVICE_EVENT = 6,   // SDL_RENDER_DEVICE_RESET
	TH_GL_GAVE_UP = 7,        // the rebuild failed three times: nothing is drawn until a restore works
	TH_GL_NOT_STARTED = 8,
	TH_GL_NOT_PRESENTED = 9, // frames are drawn but the front buffer never gets them (a silently dead surface)
};

static const char* GlCheckName(int c)
{
	switch (c)
	{
	case TH_GL_OK: return "ok";
	case TH_GL_NOT_CURRENT: return "context not current";
	case TH_GL_RESET: return "graphics reset reported";
	case TH_GL_CONTEXT_LOST: return "GL_CONTEXT_LOST";
	case TH_GL_SWAP_FAILED: return "buffer swaps failing";
	case TH_GL_NO_RENDERER: return "no renderer";
	case TH_GL_DEVICE_EVENT: return "device reset event";
	case TH_GL_GAVE_UP: return "could not be restored";
	case TH_GL_NOT_PRESENTED: return "frames not presented";
	default: return "not started";
	}
}

#ifndef GL_CONTEXT_LOST
#define GL_CONTEXT_LOST 0x0507
#endif
#ifndef GL_OUT_OF_MEMORY
#define GL_OUT_OF_MEMORY 0x0505
#endif
#ifndef APIENTRY
#define APIENTRY
#endif
typedef GLenum (APIENTRY *ThGetResetStatus)(void);
typedef void (APIENTRY *ThGenDelete)(GLsizei, GLuint*);
typedef GLboolean (APIENTRY *ThIsName)(GLuint);

static const char*      gGlslVersion = "#version 130";
static bool             gBackendUp = false;   // ImGui_ImplOpenGL3_Init done, not shut down
static bool             gRobust = false;      // the context has robust access + lose-context-on-reset
static ThGetResetStatus gGetResetStatus = nullptr;
static volatile int     gGlLastCheck = TH_GL_NOT_STARTED; // read by the editor's frame watch thread
static volatile int     gGlLastSwapMs = 0;
static volatile int     gGlMaxSwapMs = 0;
static int              gBadSwaps = 0;        // failed or > 2 s swaps in a row
static bool             gSlowSwapLogged = false;
static bool             gGlFailed = false;    // gave up: no context, nothing drawn
static std::string      gRebuildWhy;          // non-empty: rebuild at the start of the next frame
static bool             gRebuildManual = false; // the rebuild was asked for (Restore Graphics), nothing was found lost
static int              gGlGeneration = 1;    // +1 per rebuild: textures of an older generation are gone
static int              gGlRebuilds = 0;
static int              gGlWindowRecreates = 0;
static int              gGlEventLogLeft = 200;
static double           gAutoRebuildTimes[3] = { -1e9, -1e9, -1e9 };
static std::string      gStartRenderer;
static Uint32           gWindowFlagsCreated = 0;
static std::string      gWindowTitle = "Treadle";
// Self test (th_gl_simulate): the context was deleted behind the host's back; the next N context creations fail.
static bool             gContextGone = false;
static bool             gSimReset = false;
static int              gSimFailCreates = 0;
// One pixel read back from the next rendered frame (th_gl_probe_request).
static bool             gProbeWanted = false;
static int              gProbeState = 0;      // 0 none, 1 read, 2 read failed
static unsigned         gProbePixel = 0;

// Presentation watch. A driver whose presentation died silently (seen on a hybrid laptop's integrated GPU with an
// overlay hooked into the process) keeps drawing frames with no GL error while the window shows nothing new. Once a
// second a 1x1 marker is drawn into the corner of the back buffer (its grey one step above or below the clear colour,
// alternating: not visible), and after the swap the front buffer is read there. Three misses in a row (about 3 s of
// frames not presented) is a lost surface: a new context, a second one, then a new window, then the watch stops
// until Restore Graphics. It arms only after its first hit, so a driver whose front buffer cannot be read back
// never triggers it.
static bool             gPresentArmed = false;
static int              gPresentMisses = 0;
static double           gPresentFirstMiss = 0;
static double           gPresentNext = 0;
static unsigned         gPresentSeq = 0;
static int              gPresentRebuilds = 0;  // rebuilds for presentation since the last hit
static bool             gPresentGaveUp = false;
static bool             gForceNewWindow = false; // the next rebuild opens a new window
static int              gSimNoPresent = 0;     // self test: the next N probes miss

// The drawing state in one exported block, for the editor's frame watch and for a crash dump (find it by the export
// th_gl_diag or by its magic "THGLDIAG"). Plain fields, written on the frame thread, read anywhere.
struct ThGlDiag
{
	char               Magic[8];
	void*              Context;
	void*              Window;
	volatile int       LastCheck;
	volatile int       LastSwapMs;
	volatile int       MaxSwapMs;
	volatile int       Rebuilds;
	volatile int       WindowRecreates;
	volatile int       Generation;
	volatile int       PresentArmed;
	volatile int       PresentGaveUp;
	volatile long long Swaps;
	volatile long long PresentHits;
	volatile long long PresentMisses;
	char               LastSdlError[160];
	char               Renderer[160];
	char               Overlays[256];
};
TH_API ThGlDiag th_gl_diag = { { 'T', 'H', 'G', 'L', 'D', 'I', 'A', 'G' } };

static void CopyText(char* dst, size_t cap, const char* src)
{
	if (src == nullptr)
		src = "";
	size_t n = strlen(src);
	if (n >= cap)
		n = cap - 1;
	memcpy(dst, src, n);
	dst[n] = 0;
}

// Clears pending GL errors, at most 32: with no current context (a lost device) some drivers report an error on
// every call, so an unbounded loop would never end.
static void DrainGlErrors()
{
	for (int i = 0; i < 32 && glGetError() != GL_NO_ERROR; i++) {}
}

static double NowSeconds() { return (double)SDL_GetPerformanceCounter() / (double)SDL_GetPerformanceFrequency(); }

static void LoadResetStatus()
{
	gGetResetStatus = nullptr;
	if (!gRobust)
		return;
	const char* names[] = { "glGetGraphicsResetStatus", "glGetGraphicsResetStatusARB", "glGetGraphicsResetStatusKHR", "glGetGraphicsResetStatusEXT" };
	for (const char* n : names)
	{
		gGetResetStatus = (ThGetResetStatus)SDL_GL_GetProcAddress(n);
		if (gGetResetStatus != nullptr)
			break;
	}
}

// A context for `w`: robust access with lose-context-on-reset first (a driver reset is then reported instead of
// leaving a context that silently draws nothing), a plain one when the driver has no robustness.
static SDL_GLContext CreateGLContext(SDL_Window* w)
{
	if (gSimFailCreates > 0)
	{
		gSimFailCreates--;
		SDL_SetError("forced by the glreset self test");
		return nullptr;
	}
#if !defined(__APPLE__)
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_ROBUST_ACCESS_FLAG);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_RESET_NOTIFICATION, SDL_GL_CONTEXT_RESET_LOSE_CONTEXT);
	SDL_GLContext c = SDL_GL_CreateContext(w);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, 0);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_RESET_NOTIFICATION, SDL_GL_CONTEXT_RESET_NO_NOTIFICATION);
	if (c != nullptr)
	{
		gRobust = true;
		return c;
	}
#endif
	gRobust = false;
	return SDL_GL_CreateContext(w);
}

// The current-context test of every frame. Windows asks WGL itself (SDL only remembers what it made current).
static bool ContextCurrent()
{
	if (gGLContext == nullptr || gContextGone)
		return false;
#if defined(_WIN32)
	return wglGetCurrentContext() == (HGLRC)gGLContext;
#else
	return SDL_GL_GetCurrentContext() == gGLContext;
#endif
}

// The per-frame check (`deep`: also asks the driver for its renderer, on window and display events).
static int GlCheckNow(bool deep)
{
	if (gGlFailed)
		return TH_GL_GAVE_UP;
	if (!ContextCurrent())
		return TH_GL_NOT_CURRENT;
	if (gSimReset)
	{
		gSimReset = false;
		return TH_GL_RESET;
	}
	if (gGetResetStatus != nullptr && gGetResetStatus() != 0)
		return TH_GL_RESET;
	if (deep && glGetString(GL_RENDERER) == nullptr)
		return TH_GL_NO_RENDERER;
	return TH_GL_OK;
}

static void ScheduleRebuild(int check, const char* event)
{
	if (!gRebuildWhy.empty() || gGlFailed)
		return;
	char why[256];
	if (check == TH_GL_OK)
		snprintf(why, sizeof(why), "%s", event);
	else
		snprintf(why, sizeof(why), "%s (%s)", event, GlCheckName(check));
	gRebuildWhy = why;
}

#if defined(_WIN32)
static HWND WindowHandle(SDL_Window* w)
{
	SDL_SysWMinfo wm;
	SDL_VERSION(&wm.version);
	if (w != nullptr && SDL_GetWindowWMInfo(w, &wm) && wm.subsystem == SDL_SYSWM_WINDOWS)
		return wm.info.win.window;
	return nullptr;
}
#endif

// Shows a quiet window (created hidden) without activating it, at posX/posY (th_set_window_quiet).
static void ShowQuietWindow(SDL_Window* w, int posX, int posY)
{
#if defined(_WIN32)
	HWND hwnd = WindowHandle(w);
	if (hwnd != nullptr)
	{
		LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
		SetWindowLongPtrW(hwnd, GWL_EXSTYLE, (ex | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW) & ~(LONG_PTR)WS_EX_APPWINDOW);
		SetWindowPos(hwnd, HWND_BOTTOM, posX, posY, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
		ShowWindow(hwnd, SW_SHOWNOACTIVATE);
	}
	else
		SDL_ShowWindow(w);
#else
	SDL_ShowWindow(w);
	SDL_SetWindowPosition(w, posX, posY); // a window manager may have placed it on map
#endif
}

static void SetWindowIconFromHeader(SDL_Window* w)
{
	// The Treadle icon on the title bar, the taskbar and Alt+Tab (Windows), and in X11 / Wayland shells.
	SDL_Surface* icon = SDL_CreateRGBSurfaceWithFormatFrom((void*)kTreadleIconRGBA, kTreadleIconWidth, kTreadleIconHeight, 32,
		kTreadleIconWidth * 4, SDL_PIXELFORMAT_ABGR8888);
	if (icon != nullptr)
	{
		SDL_SetWindowIcon(w, icon);
		SDL_FreeSurface(icon);
	}
}

// A new window at the place and size of the old one (same flags, maximized again when it was), for a driver that
// will not give the old window a new context. Returns it, or null; the caller swaps it in.
static SDL_Window* NewWindowLikeOld()
{
	int x = 0, y = 0, w = 0, h = 0;
	SDL_GetWindowPosition(gWindow, &x, &y);
	SDL_GetWindowSize(gWindow, &w, &h);
	Uint32 now = SDL_GetWindowFlags(gWindow);
	Uint32 flags = gWindowFlagsCreated | SDL_WINDOW_HIDDEN;
	SDL_Window* nw = SDL_CreateWindow(gWindowTitle.c_str(), x, y, w > 0 ? w : 1280, h > 0 ? h : 800, flags);
	if (nw == nullptr)
		return nullptr;
	SetWindowIconFromHeader(nw);
	if (gQuiet)
		ShowQuietWindow(nw, x, y);
	else
	{
		SDL_ShowWindow(nw);
		if (now & SDL_WINDOW_MAXIMIZED)
			SDL_MaximizeWindow(nw);
		if (now & SDL_WINDOW_MINIMIZED)
			SDL_MinimizeWindow(nw);
	}
	return nw;
}


// Overlays that hook a process's presentation (they draw their own layer into every frame) and are known to stop or
// stall OpenGL presentation with some drivers. Logged at start and after each rebuild; kept in th_gl_diag.
static void LogOverlays(const char* when)
{
#if defined(_WIN32)
	struct Known { const char* Dll; const char* What; };
	static const Known known[] = {
		{ "nahimicosd.dll", "Nahimic audio overlay (Alienware, Dell and MSI sound software)" },
		{ "rtsshooks64.dll", "RivaTuner Statistics Server" },
		{ "discordhook64.dll", "Discord overlay" },
		{ "gameoverlayrenderer64.dll", "Steam overlay" },
		{ "nvspcap64.dll", "NVIDIA overlay (ShadowPlay)" },
		{ "igo64.dll", "EA overlay" },
		{ "owclient.dll", "Overwolf" },
		{ "fpsmonitor64.dll", "FPS Monitor" },
	};
	HMODULE mods[1024];
	DWORD needed = 0;
	std::string found;
	if (K32EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &needed))
	{
		DWORD count = needed / sizeof(HMODULE);
		if (count > 1024)
			count = 1024;
		for (DWORD i = 0; i < count; i++)
		{
			char name[MAX_PATH];
			if (K32GetModuleBaseNameA(GetCurrentProcess(), mods[i], name, MAX_PATH) == 0)
				continue;
			for (char* p = name; *p; p++)
				*p = (char)tolower((unsigned char)*p);
			for (const Known& k : known)
				if (strcmp(name, k.Dll) == 0)
				{
					if (!found.empty())
						found += ", ";
					found += std::string(k.Dll) + " (" + k.What + ")";
				}
		}
	}
	CopyText(th_gl_diag.Overlays, sizeof(th_gl_diag.Overlays), found.c_str());
	GlLog("[gl] %s: overlays hooked into the process: %s", when, found.empty() ? "none known" : found.c_str());
#else
	(void)when;
#endif
}

// th_gl_diag from the host's state (cheap: plain stores).
static void SyncDiag()
{
	th_gl_diag.Context = gGLContext;
	th_gl_diag.Window = gWindow;
	th_gl_diag.LastCheck = gGlLastCheck;
	th_gl_diag.LastSwapMs = gGlLastSwapMs;
	th_gl_diag.MaxSwapMs = gGlMaxSwapMs;
	th_gl_diag.Rebuilds = gGlRebuilds;
	th_gl_diag.WindowRecreates = gGlWindowRecreates;
	th_gl_diag.Generation = gGlGeneration;
	th_gl_diag.PresentArmed = gPresentArmed ? 1 : 0;
	th_gl_diag.PresentGaveUp = gPresentGaveUp ? 1 : 0;
}

static void LogGlIdentity(const char* when)
{
	const char* vendor = (const char*)glGetString(GL_VENDOR);
	const char* renderer = (const char*)glGetString(GL_RENDERER);
	const char* version = (const char*)glGetString(GL_VERSION);
	const char* driver = SDL_GetCurrentVideoDriver();
	GlLog("[gl] %s: OpenGL %s, %s, %s; video driver %s; robustness %s; swap interval %d", when,
		version ? version : "?", vendor ? vendor : "?", renderer ? renderer : "?", driver ? driver : "?",
		gRobust ? (gGetResetStatus != nullptr ? "on" : "on (no reset query)") : "off", SDL_GL_GetSwapInterval());
	CopyText(th_gl_diag.Renderer, sizeof(th_gl_diag.Renderer), renderer);
	if (renderer != nullptr)
	{
		if (gStartRenderer.empty())
			gStartRenderer = renderer;
		else if (gStartRenderer != renderer)
			GlLog("[gl] the renderer changed: %s at start, %s now", gStartRenderer.c_str(), renderer);
	}
}

// One rebuild attempt: a new context (on a new window if the old one will not take one), the renderer objects, the
// swap interval. The new context is made current before the old renderer objects are released, so no GL call ever
// goes to a dead context (names that do not exist in the new one are ignored).
static bool RebuildOnce()
{
	SDL_Window* target = gWindow;
	SDL_Window* fresh = nullptr;
	SDL_GLContext c = nullptr;
	if (gForceNewWindow)
	{
		gForceNewWindow = false;
		GlLog("[gl] new contexts did not bring presentation back: opening a new window at the same place");
	}
	else
	{
		c = CreateGLContext(gWindow);
		if (c == nullptr)
			GlLog("[gl] no new context for the window (%s): opening a new window at the same place", SDL_GetError());
	}
	if (c == nullptr)
	{
		fresh = NewWindowLikeOld();
		if (fresh == nullptr)
		{
			GlLog("[gl] the new window could not be created: %s", SDL_GetError());
			return false;
		}
		c = CreateGLContext(fresh);
		if (c == nullptr)
		{
			GlLog("[gl] no context for the new window either: %s", SDL_GetError());
			SDL_DestroyWindow(fresh);
			return false;
		}
		target = fresh;
	}
	if (SDL_GL_MakeCurrent(target, c) != 0)
	{
		GlLog("[gl] the new context cannot be made current: %s", SDL_GetError());
		SDL_GL_DeleteContext(c);
		if (fresh != nullptr)
			SDL_DestroyWindow(fresh);
		return false;
	}
	if (gBackendUp)
	{
		ImGui_ImplOpenGL3_Shutdown(); // drops shaders, buffers and textures; ImGui marks its textures for re-upload
		gBackendUp = false;
	}
	if (gGLContext != nullptr && !gContextGone)
		SDL_GL_DeleteContext(gGLContext);
	gGLContext = c;
	gContextGone = false;
	if (fresh != nullptr)
	{
		ImGui_ImplSDL2_Shutdown();
		SDL_DestroyWindow(gWindow);
		gWindow = fresh;
		ImGui_ImplSDL2_InitForOpenGL(gWindow, gGLContext);
		gGlWindowRecreates++;
		int d = SDL_GetWindowDisplayIndex(gWindow);
		if (d >= 0)
			gWindowScale = DisplayScale(d);
	}
	SDL_GL_SetSwapInterval(1);
	LoadResetStatus();
	if (!ImGui_ImplOpenGL3_Init(gGlslVersion))
	{
		GlLog("[gl] the renderer could not start on the new context");
		return false;
	}
	gBackendUp = true;
	if (!ImGui_ImplOpenGL3_CreateDeviceObjects())
	{
		GlLog("[gl] the renderer's shaders could not be built on the new context");
		return false;
	}
	DrainGlErrors(); // names of the old context released in the new one
	return GlCheckNow(true) == TH_GL_OK;
}

static void PaintFailedMessage();

// The rebuild with its bounded retries. Runs at the start of a frame (never inside one).
static void RunRebuild()
{
	std::string why = gRebuildWhy;
	gRebuildWhy.clear();
	if (gRebuildManual)
		GlLog("[gl] restore requested (%s): recreating", why.c_str());
	else
		GlLog("[gl] context lost after %s: recreating", why.c_str());
	gRebuildManual = false;
	bool ok = false;
	for (int attempt = 1; attempt <= 3 && !ok; attempt++)
	{
		if (attempt > 1)
			SDL_Delay(500);
		ok = RebuildOnce();
		if (!ok)
			GlLog("[gl] rebuild attempt %d of 3 failed", attempt);
	}
	gBadSwaps = 0;
	gSlowSwapLogged = false;
	if (ok)
	{
		gGlFailed = false;
		gGlGeneration++;
		gGlRebuilds++;
		gGlLastCheck = TH_GL_OK;
		LogGlIdentity("restored");
		LogOverlays("restored");
		gPresentMisses = 0;
		gPresentNext = NowSeconds() + 1.0;
		SyncDiag();
		SDL_SetWindowTitle(gWindow, gWindowTitle.c_str());
		return;
	}
	gGlFailed = true;
	gGlLastCheck = TH_GL_GAVE_UP;
	SyncDiag();
	// No GL call is made until a rebuild works (the renderer is released then, under the new context). Without a
	// renderer at all, ImGui keeps running: its textures wait for one (WantCreate) instead of asserting.
	if (!gBackendUp)
		ImGui::GetIO().BackendFlags |= ImGuiBackendFlags_RendererHasTextures | ImGuiBackendFlags_RendererHasVtxOffset;
	GlLog("[gl] the graphics device could not be restored: the window shows a message; autosave goes on; Window > Restore Graphics (Ctrl+Alt+R) tries again");
#if !defined(_WIN32)
	SDL_SetWindowTitle(gWindow, "Treadle - the graphics device was lost and could not be restored. Save All and restart.");
#endif
}

// Windows: the message of a failed restore, drawn with GDI (needs no OpenGL), at most twice a second.
static void PaintFailedMessage()
{
#if defined(_WIN32)
	static double last = 0;
	double now = NowSeconds();
	if (now - last < 0.5)
		return;
	last = now;
	HWND hwnd = WindowHandle(gWindow);
	if (hwnd == nullptr)
		return;
	HDC dc = GetDC(hwnd);
	if (dc == nullptr)
		return;
	RECT rc;
	GetClientRect(hwnd, &rc);
	HBRUSH bg = CreateSolidBrush(RGB(32, 32, 32));
	FillRect(dc, &rc, bg);
	DeleteObject(bg);
	SetBkMode(dc, TRANSPARENT);
	SetTextColor(dc, RGB(235, 235, 235));
	const wchar_t* text = L"The graphics device was lost and could not be restored. Save All and restart.\n\n"
		L"(Window > Restore Graphics or Ctrl+Alt+R tries again.)";
	RECT tr = rc;
	DrawTextW(dc, text, -1, &tr, DT_CENTER | DT_WORDBREAK | DT_CALCRECT);
	int th = tr.bottom - tr.top;
	tr.left = rc.left + 16;
	tr.right = rc.right - 16;
	tr.top = rc.top + (rc.bottom - rc.top - th) / 2;
	tr.bottom = tr.top + th + 4;
	DrawTextW(dc, text, -1, &tr, DT_CENTER | DT_WORDBREAK);
	ReleaseDC(hwnd, dc);
#endif
}

// Window and display events that come with a device change: a fuller check, logged (bounded).
static void CheckOnEvent(const char* event, bool log)
{
	int c = GlCheckNow(true);
	gGlLastCheck = c;
	if (log && gGlEventLogLeft > 0)
	{
		gGlEventLogLeft--;
		GlLog("[gl] %s: drawing context %s (current %s, last present %d ms)", event, GlCheckName(c), ContextCurrent() ? "yes" : "no", (int)gGlLastSwapMs);
	}
	if (c != TH_GL_OK && c != TH_GL_GAVE_UP)
		ScheduleRebuild(c, event);
}

static void HandleDeviceEvent(const SDL_Event& e)
{
	if (e.type == SDL_RENDER_DEVICE_RESET)
	{
		ScheduleRebuild(TH_GL_DEVICE_EVENT, "a device reset event");
		return;
	}
	if (e.type == SDL_RENDER_TARGETS_RESET)
	{
		CheckOnEvent("a render targets reset", true);
		return;
	}
	if (e.type == SDL_DISPLAYEVENT)
	{
		CheckOnEvent(e.display.event == SDL_DISPLAYEVENT_CONNECTED ? "a display connected" :
			e.display.event == SDL_DISPLAYEVENT_DISCONNECTED ? "a display disconnected" : "a display change", true);
		return;
	}
	if (e.type != SDL_WINDOWEVENT || gWindow == nullptr || e.window.windowID != SDL_GetWindowID(gWindow))
		return;
	switch (e.window.event)
	{
	case SDL_WINDOWEVENT_DISPLAY_CHANGED: CheckOnEvent("the window moved to another display", true); break;
	case SDL_WINDOWEVENT_RESTORED: CheckOnEvent("the window was restored", true); break;
	case SDL_WINDOWEVENT_FOCUS_GAINED: CheckOnEvent("the window got the focus", true); break;
	case SDL_WINDOWEVENT_SIZE_CHANGED: CheckOnEvent("a size change", false); break;
	case SDL_WINDOWEVENT_EXPOSED: CheckOnEvent("an expose", false); break;
	default: break;
	}
}

// Every frame, after drawing: GL errors that mean a lost device, then the swap with its time.
static void SwapAndWatch()
{
	if (gProbeWanted)
	{
		gProbeWanted = false;
		ImGuiIO& io = ImGui::GetIO();
		int fbW = (int)(io.DisplaySize.x * io.DisplayFramebufferScale.x);
		int fbH = (int)(io.DisplaySize.y * io.DisplayFramebufferScale.y);
		DrainGlErrors();
		unsigned px = 0xDEADBEEFu;
		glPixelStorei(GL_PACK_ALIGNMENT, 1);
		glReadBuffer(GL_BACK);
		glReadPixels(fbW / 2, fbH / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &px);
		gProbePixel = px;
		gProbeState = (glGetError() == GL_NO_ERROR && px != 0xDEADBEEFu) ? 1 : 2;
	}
	for (int i = 0; i < 8; i++)
	{
		GLenum err = glGetError();
		if (err == GL_NO_ERROR)
			break;
		if (err == GL_CONTEXT_LOST)
		{
			gGlLastCheck = TH_GL_CONTEXT_LOST;
			ScheduleRebuild(TH_GL_CONTEXT_LOST, "a draw");
			break;
		}
	}
	// The presentation watch's marker (see gPresentArmed), once a second.
	ImGuiIO& pio = ImGui::GetIO();
	int pw = (int)(pio.DisplaySize.x * pio.DisplayFramebufferScale.x);
	int ph = (int)(pio.DisplaySize.y * pio.DisplayFramebufferScale.y);
	double tnow = NowSeconds();
	bool probe = pw > 0 && ph > 0 && tnow >= gPresentNext && !gPresentGaveUp &&
		(SDL_GetWindowFlags(gWindow) & SDL_WINDOW_MINIMIZED) == 0;
	unsigned mark = 0;
	if (probe)
	{
		gPresentNext = tnow + 1.0;
		gPresentSeq++;
		mark = (gPresentSeq & 1) ? 21u : 19u; // the clear colour is 20 (0.08)
		GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);
		glEnable(GL_SCISSOR_TEST);
		glScissor(pw - 1, 0, 1, 1);
		glClearColor(mark / 255.0f, mark / 255.0f, mark / 255.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		if (!scissor)
			glDisable(GL_SCISSOR_TEST);
	}
	SDL_ClearError();
	double t0 = NowSeconds();
	SDL_GL_SwapWindow(gWindow);
	int ms = (int)((NowSeconds() - t0) * 1000.0);
	th_gl_diag.Swaps++;
	if (probe)
	{
		DrainGlErrors();
		unsigned px = 0;
		glPixelStorei(GL_PACK_ALIGNMENT, 1);
		glReadBuffer(GL_FRONT);
		glReadPixels(pw - 1, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &px);
		glReadBuffer(GL_BACK);
		bool hit = glGetError() == GL_NO_ERROR && (px & 0xFFu) == mark && ((px >> 8) & 0xFFu) == mark;
		if (gSimNoPresent > 0)
		{
			gSimNoPresent--;
			hit = false;
		}
		if (hit)
		{
			if (!gPresentArmed)
				GlLog("[gl] presentation watch on (the front buffer reads back)");
			gPresentArmed = true;
			gPresentMisses = 0;
			gPresentRebuilds = 0;
			th_gl_diag.PresentHits++;
		}
		else if (gPresentArmed)
		{
			th_gl_diag.PresentMisses++;
			if (gPresentMisses == 0)
				gPresentFirstMiss = tnow;
			gPresentMisses++;
			if (gPresentMisses >= 3 && tnow - gPresentFirstMiss >= 1.9)
			{
				gPresentMisses = 0;
				if (gPresentRebuilds >= 3)
				{
					gPresentGaveUp = true;
					GlLog("[gl] frames are still not presented after two new contexts and a new window: the watch stops (Window > Restore Graphics tries again)");
				}
				else
				{
					gPresentRebuilds++;
					if (gPresentRebuilds >= 3)
						gForceNewWindow = true; // context first, twice; then the window
					gGlLastCheck = TH_GL_NOT_PRESENTED;
					ScheduleRebuild(TH_GL_NOT_PRESENTED, "3 s of frames drawn but not presented");
				}
			}
		}
	}
	gGlLastSwapMs = ms;
	if (ms > gGlMaxSwapMs)
		gGlMaxSwapMs = ms;
	const char* err = SDL_GetError();
	bool failed = err != nullptr && err[0] != 0;
	if (failed)
		CopyText(th_gl_diag.LastSdlError, sizeof(th_gl_diag.LastSdlError), err);
	bool minimized = (SDL_GetWindowFlags(gWindow) & SDL_WINDOW_MINIMIZED) != 0;
	if ((failed || ms > 2000) && !minimized)
	{
		gBadSwaps++;
		if (!gSlowSwapLogged)
		{
			gSlowSwapLogged = true;
			GlLog("[gl] buffer swap %s (%d ms)%s%s", failed ? "failed" : "took over 2 s", ms, failed ? ": " : "", failed ? err : "");
		}
		int c = GlCheckNow(true);
		gGlLastCheck = c;
		if (c != TH_GL_OK)
			ScheduleRebuild(c, "a slow or failed buffer swap");
		else if (gBadSwaps >= 3)
		{
			// Rebuilt at most three times a minute for swaps alone (a driver that fails swaps for another reason).
			double now = NowSeconds();
			if (now - gAutoRebuildTimes[0] > 60.0)
			{
				gAutoRebuildTimes[0] = gAutoRebuildTimes[1];
				gAutoRebuildTimes[1] = gAutoRebuildTimes[2];
				gAutoRebuildTimes[2] = now;
				ScheduleRebuild(TH_GL_SWAP_FAILED, "three failed or slow buffer swaps");
			}
		}
	}
	else
	{
		gBadSwaps = 0;
		if (!failed)
			gSlowSwapLogged = false;
	}
	SyncDiag();
}

// The result of the last check (ThGlCheck), for the editor's frame watch and log lines. Thread-safe to read.
TH_API int th_gl_check() { return gGlLastCheck; }
// How long the last buffer swap took, and the longest one so far (ms). Thread-safe to read.
TH_API int th_gl_last_swap_ms() { return gGlLastSwapMs; }
TH_API int th_gl_max_swap_ms() { return gGlMaxSwapMs; }
// The name of a check result.
TH_API const char* th_gl_check_name(int check) { return GlCheckName(check); }
// 1 after the rebuild gave up (nothing is drawn, the window shows the message).
TH_API int th_gl_failed() { return gGlFailed ? 1 : 0; }
// +1 per successful rebuild: GL names (textures) the editor made under an older generation no longer exist.
TH_API int th_gl_generation() { return gGlGeneration; }
TH_API int th_gl_rebuilds() { return gGlRebuilds; }
TH_API int th_gl_window_recreates() { return gGlWindowRecreates; }
// Rebuilds the drawing side at the start of the next frame (Window > Restore Graphics), also after a failed one.
TH_API void th_gl_request_restore(const char* why)
{
	gPresentGaveUp = false;
	gPresentRebuilds = 0;
	gPresentMisses = 0;
	gGlFailed = false;
	gRebuildWhy.clear();
	ScheduleRebuild(TH_GL_OK, why != nullptr && why[0] != 0 ? why : "a restore request");
	gRebuildManual = true;
}

// Self test: simulates a lost device. 1 = the context is deleted behind the host's back; 2 = the next check reports a
// driver reset; 3 = 1, and the next three context creations fail (the new-window path and a retry); 4 = 1, and the next
// six fail (the rebuild gives up).
TH_API void th_gl_simulate(int mode)
{
	if (mode == 2)
	{
		gSimReset = true;
		return;
	}
	if (mode == 5 || mode == 6)
	{
		gSimNoPresent = mode == 5 ? 3 : 9; // 5: one rebuild brings it back; 6: two contexts, then a new window
		return;
	}
	if (gGLContext != nullptr && !gContextGone)
	{
#if defined(_WIN32)
		wglMakeCurrent(nullptr, nullptr);
		wglDeleteContext((HGLRC)gGLContext);
#else
		SDL_GL_MakeCurrent(gWindow, nullptr);
		SDL_GL_DeleteContext(gGLContext);
#endif
		gContextGone = true;
	}
	if (mode == 3)
		gSimFailCreates = 3;
	if (mode == 4)
		gSimFailCreates = 6;
}

// The presentation watch: 1 once the front buffer read back the marker; frames swapped, marker hits and misses.
TH_API int th_gl_present_armed() { return gPresentArmed ? 1 : 0; }
TH_API long long th_gl_swaps() { return th_gl_diag.Swaps; }
TH_API long long th_gl_present_hits() { return th_gl_diag.PresentHits; }
TH_API long long th_gl_present_misses() { return th_gl_diag.PresentMisses; }
// The last error a buffer swap reported (empty when none did). Static text: safe from any thread.
TH_API const char* th_gl_last_sdl_error() { return th_gl_diag.LastSdlError; }

// Reads one pixel (the middle of the window) of the next frame before it is presented.
TH_API void th_gl_probe_request() { gProbeWanted = true; gProbeState = 0; }
// 0 = not read yet, 1 = read (*rgba = the pixel, R in the low byte), 2 = the read failed.
TH_API int th_gl_probe_result(unsigned* rgba)
{
	if (rgba != nullptr)
		*rgba = gProbePixel;
	return gProbeState;
}

// Self test: sends the window an SDL window event (SDL_WINDOWEVENT_FOCUS_LOST = 13, FOCUS_GAINED = 12, ...), as the
// platform layer would.
TH_API void th_push_window_event(int windowEvent)
{
	if (gWindow == nullptr)
		return;
	SDL_Event e;
	SDL_zero(e);
	e.type = SDL_WINDOWEVENT;
	e.window.windowID = SDL_GetWindowID(gWindow);
	e.window.event = (Uint8)windowEvent;
	e.window.timestamp = SDL_GetTicks();
	SDL_PushEvent(&e);
}

// Long-run statistics (the soak self test): process memory, live GL objects of the host's context, ImGui's textures and
// font atlas, and the GPU memory the driver reports. -1 = not available here.
struct ThSoakStats
{
	long long PrivateBytes;      // Windows: PrivateUsage; Linux: VmRSS + swap of the process
	long long GpuProcessBytes;   // Windows: this process's local video memory use (DXGI QueryVideoMemoryInfo, all adapters)
	long long GpuAvailableKb;    // GL_NVX_gpu_memory_info current available / GL_ATI_meminfo free texture memory
	int LiveTextures;
	int LiveBuffers;
	int LiveVertexArrays;
	int LivePrograms;
	int LiveShaders;
	int HighestName;             // the largest GL name a fresh glGen* returns (a name leak shows as steady growth)
	int ImGuiTextures;           // textures ImGui keeps (font atlas and others)
	int AtlasWidth;
	int AtlasHeight;
	int BakedFonts;              // font sizes baked into the atlas
	int Frames;
};

static int gFrames = 0;

#if defined(_WIN32)
#include <psapi.h>
#include <dxgi1_4.h>
static long long GpuProcessBytes()
{
	static HMODULE dxgi = LoadLibraryA("dxgi.dll");
	if (dxgi == nullptr)
		return -1;
	typedef HRESULT (WINAPI *CreateFactory1)(REFIID, void**);
	static CreateFactory1 create = (CreateFactory1)(void*)GetProcAddress(dxgi, "CreateDXGIFactory1");
	if (create == nullptr)
		return -1;
	IDXGIFactory1* factory = nullptr;
	if (FAILED(create(__uuidof(IDXGIFactory1), (void**)&factory)) || factory == nullptr)
		return -1;
	long long total = 0;
	bool any = false;
	IDXGIAdapter1* adapter = nullptr;
	for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; i++)
	{
		IDXGIAdapter3* a3 = nullptr;
		if (SUCCEEDED(adapter->QueryInterface(__uuidof(IDXGIAdapter3), (void**)&a3)) && a3 != nullptr)
		{
			DXGI_QUERY_VIDEO_MEMORY_INFO info;
			if (SUCCEEDED(a3->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info)))
			{
				total += (long long)info.CurrentUsage;
				any = true;
			}
			if (SUCCEEDED(a3->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, &info)))
				total += (long long)info.CurrentUsage;
			a3->Release();
		}
		adapter->Release();
	}
	factory->Release();
	return any ? total : -1;
}
#endif

static int CountLive(ThIsName isName, int highest)
{
	if (isName == nullptr)
		return -1;
	int n = 0;
	for (int i = 1; i <= highest; i++)
		if (isName((GLuint)i))
			n++;
	return n;
}

TH_API void th_soak_stats(ThSoakStats* s)
{
	if (s == nullptr)
		return;
	memset(s, 0, sizeof(*s));
	s->PrivateBytes = -1;
	s->GpuProcessBytes = -1;
	s->GpuAvailableKb = -1;
	s->Frames = gFrames;
#if defined(_WIN32)
	PROCESS_MEMORY_COUNTERS_EX pmc;
	pmc.cb = sizeof(pmc);
	if (K32GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS*)&pmc, sizeof(pmc)))
		s->PrivateBytes = (long long)pmc.PrivateUsage;
	s->GpuProcessBytes = GpuProcessBytes();
#else
	FILE* f = fopen("/proc/self/status", "r");
	if (f != nullptr)
	{
		char line[256];
		long long kb = 0;
		while (fgets(line, sizeof(line), f))
			if (strncmp(line, "VmRSS:", 6) == 0 || strncmp(line, "VmSwap:", 7) == 0)
				kb += atoll(strchr(line, ':') + 1);
		fclose(f);
		s->PrivateBytes = kb * 1024;
	}
#endif
	ImGuiIO& io = ImGui::GetIO();
	s->ImGuiTextures = ImGui::GetPlatformIO().Textures.Size;
	if (io.Fonts->TexData != nullptr)
	{
		s->AtlasWidth = io.Fonts->TexData->Width;
		s->AtlasHeight = io.Fonts->TexData->Height;
	}
	s->BakedFonts = io.Fonts->Builder != nullptr ? io.Fonts->Builder->BakedMap.Data.Size : -1;
	if (!ContextCurrent())
	{
		s->LiveTextures = s->LiveBuffers = s->LiveVertexArrays = s->LivePrograms = s->LiveShaders = s->HighestName = -1;
		return;
	}
	ThGenDelete genTex = (ThGenDelete)SDL_GL_GetProcAddress("glGenTextures");
	ThGenDelete delTex = (ThGenDelete)SDL_GL_GetProcAddress("glDeleteTextures");
	ThGenDelete genBuf = (ThGenDelete)SDL_GL_GetProcAddress("glGenBuffers");
	ThGenDelete delBuf = (ThGenDelete)SDL_GL_GetProcAddress("glDeleteBuffers");
	ThGenDelete genVao = (ThGenDelete)SDL_GL_GetProcAddress("glGenVertexArrays");
	ThGenDelete delVao = (ThGenDelete)SDL_GL_GetProcAddress("glDeleteVertexArrays");
	int highest = 0;
	GLuint n = 0;
#if defined(_WIN32)
	// GL 1.1 entry points come from opengl32.dll itself (wglGetProcAddress does not return them).
	n = 0; glGenTextures(1, &n); if ((int)n > highest) highest = (int)n; glDeleteTextures(1, &n);
	(void)genTex; (void)delTex;
#else
	if (genTex && delTex) { n = 0; genTex(1, &n); if ((int)n > highest) highest = (int)n; delTex(1, &n); }
#endif
	if (genBuf && delBuf) { n = 0; genBuf(1, &n); if ((int)n > highest) highest = (int)n; delBuf(1, &n); }
	if (genVao && delVao) { n = 0; genVao(1, &n); if ((int)n > highest) highest = (int)n; delVao(1, &n); }
	s->HighestName = highest;
	int scan = highest + 256;
	if (scan > 200000)
		scan = 200000;
#if defined(_WIN32)
	s->LiveTextures = CountLive((ThIsName)(void*)&glIsTexture, scan);
#else
	s->LiveTextures = CountLive((ThIsName)SDL_GL_GetProcAddress("glIsTexture"), scan);
#endif
	s->LiveBuffers = CountLive((ThIsName)SDL_GL_GetProcAddress("glIsBuffer"), scan);
	s->LiveVertexArrays = CountLive((ThIsName)SDL_GL_GetProcAddress("glIsVertexArray"), scan);
	s->LivePrograms = CountLive((ThIsName)SDL_GL_GetProcAddress("glIsProgram"), scan);
	s->LiveShaders = CountLive((ThIsName)SDL_GL_GetProcAddress("glIsShader"), scan);
	if (SDL_GL_ExtensionSupported("GL_NVX_gpu_memory_info"))
	{
		GLint kb = 0;
		glGetIntegerv(0x9049 /* GL_GPU_MEMORY_INFO_CURRENT_AVAILABLE_VIDMEM_NVX */, &kb);
		s->GpuAvailableKb = kb;
	}
	else if (SDL_GL_ExtensionSupported("GL_ATI_meminfo"))
	{
		GLint v[4] = {};
		glGetIntegerv(0x87FC /* GL_TEXTURE_FREE_MEMORY_ATI */, v);
		s->GpuAvailableKb = v[0];
	}
	DrainGlErrors();
}

TH_API int th_init(const char* title, int width, int height)
{
	gLastError.clear();
	gQuiet = gQuietRequest >= 0 ? gQuietRequest == 1 : EnvOn("TREADLE_WINDOW_HIDDEN");
	if (gQuiet)
	{
#if !defined(_WIN32) && !defined(__APPLE__)
		UseOffscreenDriver(); // first: its SDL_Quit clears the hints
#endif
		SDL_SetHint(SDL_HINT_WINDOW_NO_ACTIVATION_WHEN_SHOWN, "1");
		SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "0");
	}
	SDL_SetAssertionHandler(ThSdlAssert, nullptr);
	// Let Windows tell us the real DPI instead of bitmap-scaling a blurry window.
#ifdef SDL_HINT_WINDOWS_DPI_AWARENESS
	SDL_SetHint(SDL_HINT_WINDOWS_DPI_AWARENESS, "permonitorv2");
#endif
	if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0)
		return InitFail("SDL_Init failed");

#if defined(__APPLE__)
	const char* glslVersion = "#version 150";
	gGlslVersion = glslVersion;
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
#else
	const char* glslVersion = "#version 130";
	gGlslVersion = glslVersion;
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, 0);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
#endif
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
	SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
	SDL_SetHint(SDL_HINT_IME_SHOW_UI, "1");

	// Open on the display the mouse is on (the user's current monitor), sized for that display.
	int startDisplay = 0;
	{
		int mx = 0, my = 0;
		SDL_GetGlobalMouseState(&mx, &my);
		int count = SDL_GetNumVideoDisplays();
		for (int d = 0; d < count; d++)
		{
			SDL_Rect r;
			if (SDL_GetDisplayBounds(d, &r) == 0 && mx >= r.x && mx < r.x + r.w && my >= r.y && my < r.y + r.h)
			{
				startDisplay = d;
				break;
			}
		}
	}
	float dpiScale = DisplayScale(startDisplay);

	SDL_WindowFlags flags = (SDL_WindowFlags)(SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
	int posX = SDL_WINDOWPOS_CENTERED_DISPLAY(startDisplay);
	int posY = SDL_WINDOWPOS_CENTERED_DISPLAY(startDisplay);
	if (gQuiet)
	{
		// Created hidden and shown below without activation, already off-screen.
		flags = (SDL_WindowFlags)(flags | SDL_WINDOW_HIDDEN | SDL_WINDOW_SKIP_TASKBAR);
		QuietPosition(startDisplay, &posX, &posY);
	}
	gWindow = SDL_CreateWindow(title, posX, posY, (int)(width * dpiScale), (int)(height * dpiScale), flags);
	if (gWindow == nullptr)
		return InitFail("SDL_CreateWindow failed");
	gWindowFlagsCreated = (Uint32)flags & ~(Uint32)SDL_WINDOW_HIDDEN;
	gWindowTitle = title != nullptr ? title : "Treadle";
	SetWindowIconFromHeader(gWindow);
	if (gQuiet)
		ShowQuietWindow(gWindow, posX, posY);
	{
		// The window's own display (the platform may have placed it elsewhere): its scale is the one that counts.
		int actual = SDL_GetWindowDisplayIndex(gWindow);
		if (actual >= 0 && actual != startDisplay)
			dpiScale = DisplayScale(actual);
		gWindowScale = dpiScale;
	}
	// TREADLE_TEST_GL_FAIL=1 makes the context step fail, to see the start-up message on a machine that has OpenGL.
	const char* forceFail = getenv("TREADLE_TEST_GL_FAIL");
	if (forceFail != nullptr && forceFail[0] != 0 && forceFail[0] != '0')
	{
		SDL_SetError("forced by TREADLE_TEST_GL_FAIL");
		return InitFail("SDL_GL_CreateContext failed");
	}
	gGLContext = CreateGLContext(gWindow);
	if (gGLContext == nullptr)
		return InitFail("SDL_GL_CreateContext failed");
	SDL_GL_MakeCurrent(gWindow, gGLContext);
	SDL_GL_SetSwapInterval(1);
	SDL_EventState(SDL_DROPFILE, SDL_ENABLE);

	IMGUI_CHECKVERSION();
	ImGui::CreateContext();
	ImNodes::CreateContext();
	ImGuiIO& io = ImGui::GetIO();
	io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
	io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
	io.IniFilename = "Treadle_layout.ini";

	// Ctrl + left drag pans the graph too (middle/right mouse are the defaults in imnodes).
	ImNodesIO& nio = ImNodes::GetIO();
	nio.LinkDetachWithModifierClick.Modifier = &ImGui::GetIO().KeyAlt;
	nio.MultipleSelectModifier.Modifier = &ImGui::GetIO().KeyCtrl;

	LoadFonts(dpiScale);
	ApplyNodeStyle();

	ImGui_ImplSDL2_InitForOpenGL(gWindow, gGLContext);
	ImGui_ImplOpenGL3_Init(glslVersion);
	gBackendUp = true;
	LoadResetStatus();
	gGlLastCheck = GlCheckNow(true);
	LogGlIdentity("start");
	LogOverlays("start");
	SyncDiag();
	return 1;
}

// Pumps events and starts an ImGui frame. Returns 0 once the user closed the window.
TH_API int th_begin_frame()
{
	SDL_Event event;
	while (SDL_PollEvent(&event))
	{
		ImGui_ImplSDL2_ProcessEvent(&event);
		HandleDeviceEvent(event);
		if (event.type == SDL_QUIT)
			gQuitRequested = true;
		if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_CLOSE &&
			event.window.windowID == SDL_GetWindowID(gWindow))
			gQuitRequested = true;
		if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_DISPLAY_CHANGED &&
			event.window.windowID == SDL_GetWindowID(gWindow))
			gWindowScale = DisplayScale(event.window.data1); // data1 = the new display index
		if (event.type == SDL_DROPFILE)
		{
			if (event.drop.file != nullptr)
			{
				if (gDrops.size() < kMaxQueuedDrops)
					gDrops.push_back(event.drop.file); // any length, never cut
				else
					fprintf(stderr, "treadlehost: more than %d dropped files waiting: ignoring %s\n", (int)kMaxQueuedDrops, event.drop.file);
				SDL_free(event.drop.file);
			}
		}
	}
	if (SDL_GetWindowFlags(gWindow) & SDL_WINDOW_MINIMIZED)
		SDL_Delay(10);

	// The device check of every frame, and a rebuild when this or the last frame found the context gone.
	if (!gGlFailed && gRebuildWhy.empty())
	{
		int c = GlCheckNow(false);
		gGlLastCheck = c;
		if (c != TH_GL_OK)
			ScheduleRebuild(c, "a frame start");
	}
	if (!gRebuildWhy.empty())
		RunRebuild();
	gFrames++;
	if (gBackendUp && !gGlFailed)
		ImGui_ImplOpenGL3_NewFrame();
	ImGui_ImplSDL2_NewFrame();
	ImGui::NewFrame();
	return gQuitRequested ? 0 : 1;
}

// Framebuffer capture for test and capture scripts (TREADLE_CAPTURE_DIR=<folder>): a script writes a name
// (letters, digits, '.', '-', '_') into <folder>/capture.request; the next frame reads its OpenGL back buffer
// and writes <folder>/<name>.bmp (24-bit, the window's client area in framebuffer pixels), then deletes the
// request. It reads what was rendered, so it works for a quiet window whatever the compositor shows of it
// (an off-screen or covered window's composited image can lag behind). Off when the variable is unset.
static std::string gCaptureDir;
static bool        gCaptureDirRead = false;

static void ServeCaptureRequest(int w, int h)
{
	if (!gCaptureDirRead)
	{
		gCaptureDirRead = true;
		const char* d = getenv("TREADLE_CAPTURE_DIR");
		if (d != nullptr)
			gCaptureDir = d;
	}
	if (gCaptureDir.empty() || w <= 0 || h <= 0)
		return;
	std::string req = gCaptureDir + "/capture.request";
	FILE* f = fopen(req.c_str(), "rb");
	if (f == nullptr)
		return;
	char text[128] = {};
	size_t n = fread(text, 1, sizeof(text) - 1, f);
	fclose(f);
	std::string name;
	for (size_t i = 0; i < n && text[i] != '\r' && text[i] != '\n'; i++)
	{
		char c = text[i];
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_')
			name += c;
	}
	if (name.empty())
		name = "capture";
	int stride = (w * 3 + 3) & ~3;
	std::string pixels((size_t)w * h * 4, '\0');
	glPixelStorei(GL_PACK_ALIGNMENT, 1);
	glReadBuffer(GL_BACK);
	glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, &pixels[0]);
	// BMP rows run bottom-up, as glReadPixels returns them.
	std::string bmp(54 + (size_t)stride * h, '\0');
	auto put32 = [&](size_t at, unsigned v) { for (int k = 0; k < 4; k++) bmp[at + k] = (char)((v >> (8 * k)) & 0xFF); };
	bmp[0] = 'B';
	bmp[1] = 'M';
	put32(2, (unsigned)bmp.size());
	put32(10, 54);
	put32(14, 40);
	put32(18, (unsigned)w);
	put32(22, (unsigned)h);
	bmp[26] = 1;
	bmp[28] = 24;
	put32(34, (unsigned)((size_t)stride * h));
	for (int y = 0; y < h; y++)
	{
		const char* src = &pixels[(size_t)y * w * 4];
		char* dst = &bmp[54 + (size_t)y * stride];
		for (int x = 0; x < w; x++)
		{
			dst[x * 3 + 0] = src[x * 4 + 2];
			dst[x * 3 + 1] = src[x * 4 + 1];
			dst[x * 3 + 2] = src[x * 4 + 0];
		}
	}
	std::string path = gCaptureDir + "/" + name + ".bmp";
	std::string tmp = path + ".part";
	FILE* o = fopen(tmp.c_str(), "wb");
	if (o != nullptr)
	{
		bool ok = fwrite(bmp.data(), 1, bmp.size(), o) == bmp.size();
		ok = fclose(o) == 0 && ok;
		remove(path.c_str());
		if (!ok || rename(tmp.c_str(), path.c_str()) != 0)
			fprintf(stderr, "treadlehost: capture %s could not be written\n", path.c_str());
	}
	remove(req.c_str());
}

static volatile int gLastVtx = 0;
// Vertices ImGui built for the last frame (self tests: a panel must not flood the draw lists).
TH_API int th_last_vtx_count() { return gLastVtx; }

TH_API void th_end_frame()
{
	ImGui::Render();
	gLastVtx = ImGui::GetDrawData() != nullptr ? ImGui::GetDrawData()->TotalVtxCount : 0;
	ImGuiIO& io = ImGui::GetIO();
	int fbW = (int)(io.DisplaySize.x * io.DisplayFramebufferScale.x);
	int fbH = (int)(io.DisplaySize.y * io.DisplayFramebufferScale.y);
	if (gGlFailed || !gBackendUp)
	{
		PaintFailedMessage(); // no drawing context: the frame is built (the editor keeps working) but not drawn
		SDL_Delay(16); // no vsync to pace the loop
		return;
	}
	if (!ContextCurrent())
	{
		// lost during this frame: nothing is drawn with it; the next frame start rebuilds it
		gGlLastCheck = TH_GL_NOT_CURRENT;
		ScheduleRebuild(TH_GL_NOT_CURRENT, "a frame end");
		return;
	}
	glViewport(0, 0, fbW, fbH);
	glClearColor(0.08f, 0.08f, 0.08f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
	ServeCaptureRequest(fbW, fbH);
	SwapAndWatch();
}

// Cancels a pending quit (e.g. "unsaved changes" prompt).
TH_API void th_cancel_quit() { gQuitRequested = false; }

TH_API void th_set_title(const char* title)
{
	gWindowTitle = title != nullptr ? title : "";
	if (gWindow != nullptr && !gGlFailed)
		SDL_SetWindowTitle(gWindow, title);
}

// Returns the next file dropped onto the window (oldest first), or null when none is waiting. Call it
// until it returns null: every file dropped since the last frame is kept. The string is valid until the
// next call.
TH_API const char* th_poll_drop()
{
	if (gDrops.empty())
		return nullptr;
	gDropCurrent = std::move(gDrops.front());
	gDrops.pop_front();
	return gDropCurrent.c_str();
}

// The UI scale (1.0 = 96 dpi) of the display the window is on now; follows the window across
// monitors (SDL_WINDOWEVENT_DISPLAY_CHANGED). The editor reads it where the platform has no
// per-window DPI call of its own.
TH_API float th_get_window_scale() { return gWindowScale; }

// Brings the window to the front and gives it the keyboard (restored first when minimized).
// Windows: the editor calls SetForegroundWindow on its HWND first, because SDL_RaiseWindow alone
// does not take focus for a background process. Linux: this is the only raise. A window manager
// may still only flag the window as wanting attention (focus-stealing prevention), which is the
// platform's call.
TH_API void th_raise_window()
{
	if (gWindow == nullptr || gQuiet) // a quiet window is never raised
		return;
	if (SDL_GetWindowFlags(gWindow) & SDL_WINDOW_MINIMIZED)
		SDL_RestoreWindow(gWindow);
	SDL_RaiseWindow(gWindow);
}

// SDL_WindowFlags of the editor window (0 before th_init): minimized, input focus, ...
TH_API unsigned int th_window_flags() { return gWindow != nullptr ? (unsigned int)SDL_GetWindowFlags(gWindow) : 0u; }

TH_API ImFont* th_get_mono_font()
{
	ImGuiIO& io = ImGui::GetIO();
	return io.Fonts->Fonts.Size > 1 ? io.Fonts->Fonts[1] : nullptr;
}

TH_API void th_shutdown()
{
	if (gBackendUp)
		ImGui_ImplOpenGL3_Shutdown();
	gBackendUp = false;
	ImGui_ImplSDL2_Shutdown();
	ImNodes::DestroyContext();
	ImGui::DestroyContext();
	if (gGLContext != nullptr && !gContextGone)
		SDL_GL_DeleteContext(gGLContext);
	if (gWindow != nullptr)
		SDL_DestroyWindow(gWindow);
	SDL_Quit();
}

// Native file / folder picker.
//   pickFolder: 0 = pick a .bf file, 1 = pick a folder
// Returns 1 when something was chosen (UTF-8 path in outPath), 0 when cancelled,
// -1 when no native dialog is available (callers fall back to the ImGui browser).
#if defined(_WIN32)

// Opens the dialog in `initialDir` (UTF-8, either slash) when that folder exists; otherwise the
// dialog keeps its own start folder.
static void SetInitialFolder(IFileOpenDialog* dlg, const char* initialDir)
{
	if (initialDir == nullptr || initialDir[0] == 0)
		return;
	wchar_t wdir[4096];
	if (MultiByteToWideChar(CP_UTF8, 0, initialDir, -1, wdir, 4096) <= 0)
		return;
	for (wchar_t* c = wdir; *c; c++)
		if (*c == L'/')
			*c = L'\\';
	IShellItem* folder = nullptr;
	if (SUCCEEDED(SHCreateItemFromParsingName(wdir, nullptr, IID_PPV_ARGS(&folder))) && folder != nullptr)
	{
		dlg->SetFolder(folder);
		folder->Release();
	}
}

// The dialog's file system path, as UTF-8 in outPath. False when there is none or it does not fit.
static bool ReadDialogResult(IFileOpenDialog* dlg, char* outPath, int outCap, bool multi)
{
	bool ok = false;
	if (multi)
	{
		IShellItemArray* items = nullptr;
		DWORD count = 0;
		if (FAILED(dlg->GetResults(&items)) || items == nullptr)
			return false;
		items->GetCount(&count);
		int len = 0;
		for (DWORD i = 0; i < count; i++)
		{
			IShellItem* item = nullptr;
			if (SUCCEEDED(items->GetItemAt(i, &item)) && item != nullptr)
			{
				PWSTR wpath = nullptr;
				if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &wpath)) && wpath != nullptr)
				{
					char tmp[2048];
					if (WideCharToMultiByte(CP_UTF8, 0, wpath, -1, tmp, sizeof(tmp), nullptr, nullptr) > 0)
					{
						int n = (int)strlen(tmp);
						if (len + n + 2 <= outCap)
						{
							if (len > 0)
								outPath[len++] = '\n';
							memcpy(outPath + len, tmp, (size_t)n);
							len += n;
							outPath[len] = 0;
							ok = true;
						}
					}
					CoTaskMemFree(wpath);
				}
				item->Release();
			}
		}
		items->Release();
		return ok;
	}
	IShellItem* item = nullptr;
	if (SUCCEEDED(dlg->GetResult(&item)) && item != nullptr)
	{
		PWSTR wpath = nullptr;
		if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &wpath)) && wpath != nullptr)
		{
			ok = WideCharToMultiByte(CP_UTF8, 0, wpath, -1, outPath, outCap, nullptr, nullptr) > 0;
			CoTaskMemFree(wpath);
		}
		item->Release();
	}
	return ok;
}

// The editor window, so the dialog is modal to it (null before th_init).
static HWND OwnerWindow()
{
	if (gWindow == nullptr)
		return nullptr;
	SDL_SysWMinfo info;
	SDL_VERSION(&info.version);
	return SDL_GetWindowWMInfo(gWindow, &info) ? info.info.win.window : nullptr;
}

// mode: 0 a Treadle file, 1 a folder, 2 C headers (several), 3 any file.
static void ConfigureDialog(IFileOpenDialog* dlg, int mode)
{
	DWORD opts = 0;
	dlg->GetOptions(&opts);
	opts |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
	opts |= (mode == 1) ? FOS_PICKFOLDERS : FOS_FILEMUSTEXIST;
	if (mode == 2)
		opts |= FOS_ALLOWMULTISELECT;
	dlg->SetOptions(opts);
	if (mode == 1)
		dlg->SetTitle(L"Open Treadle Project Folder");
	else if (mode == 2)
	{
		COMDLG_FILTERSPEC filters[] = { { L"C headers (*.h;*.hpp;*.hh)", L"*.h;*.hpp;*.hh" }, { L"C import sets (*.cimport)", L"*.cimport" }, { L"All files (*.*)", L"*.*" } };
		dlg->SetFileTypes(3, filters);
		dlg->SetTitle(L"Import C headers");
	}
	else if (mode == 3)
	{
		COMDLG_FILTERSPEC filters[] = { { L"All files (*.*)", L"*.*" } };
		dlg->SetFileTypes(1, filters);
		dlg->SetTitle(L"Choose a file");
	}
	else
	{
		COMDLG_FILTERSPEC filters[] = { { L"Treadle types (*.treadle)", L"*.treadle" }, { L"Treadle projects (*.tproj)", L"*.tproj" }, { L"All files (*.*)", L"*.*" } };
		dlg->SetFileTypes(3, filters);
		dlg->SetTitle(L"Open Treadle file");
	}
}

static int NativeDialogWin32(int pickFolder, const char* initialDir, char* outPath, int outCap)
{
	HRESULT initHr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
	int result = -1;
	IFileOpenDialog* dlg = nullptr;
	HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_IFileOpenDialog, (void**)&dlg);
	if (SUCCEEDED(hr) && dlg != nullptr)
	{
		ConfigureDialog(dlg, pickFolder);
		SetInitialFolder(dlg, initialDir);
		result = (SUCCEEDED(dlg->Show(OwnerWindow())) && ReadDialogResult(dlg, outPath, outCap, pickFolder == 2)) ? 1 : 0;
		dlg->Release();
	}
	if (SUCCEEDED(initHr))
		CoUninitialize();
	return result;
}

#else

// Reads the pipe until it ends or the buffer is full; returns the byte count (outPath is terminated).
static int ReadAllFromPipe(int fd, char* outPath, int outCap)
{
	int len = 0;
	while (len < outCap - 1)
	{
		ssize_t n = read(fd, outPath + len, (size_t)(outCap - 1 - len));
		if (n <= 0)
			break;
		len += (int)n;
	}
	outPath[len] = 0;
	return len;
}

// Linux: zenity when it is installed, started without a shell (fork + execvp), so the
// folder name is one argument and never shell text. Exit 127 = zenity is missing.
static int NativeDialogZenity(int pickFolder, const char* initialDir, char* outPath, int outCap)
{
	char filenameArg[4200];
	filenameArg[0] = 0;
	if (initialDir != nullptr && initialDir[0] != 0)
		snprintf(filenameArg, sizeof(filenameArg), "--filename=%s/", initialDir);
	const char* argv[12];
	int argc = 0;
	argv[argc++] = "zenity";
	argv[argc++] = "--file-selection";
	if (pickFolder == 1)
		argv[argc++] = "--directory";
	else if (pickFolder == 2)
	{
		argv[argc++] = "--multiple";
		argv[argc++] = "--separator=\n";
		argv[argc++] = "--title=Import C headers";
		argv[argc++] = "--file-filter=C headers | *.h *.hpp *.hh";
		argv[argc++] = "--file-filter=C import sets | *.cimport";
		argv[argc++] = "--file-filter=All files | *";
	}
	else if (pickFolder == 3)
		argv[argc++] = "--file-filter=All files | *";
	else
	{
		argv[argc++] = "--file-filter=Treadle types | *.treadle";
		argv[argc++] = "--file-filter=Treadle projects | *.tproj";
		argv[argc++] = "--file-filter=All files | *";
	}
		argv[argc++] = filenameArg;
	argv[argc] = nullptr;
	int fds[2];
	if (pipe(fds) != 0)
		return -1;
	pid_t pid = fork();
	if (pid < 0)
	{
		close(fds[0]);
		close(fds[1]);
		return -1;
	}
	if (pid == 0)
	{
		dup2(fds[1], 1);
		close(fds[0]);
		close(fds[1]);
		int devNull = open("/dev/null", O_WRONLY);
		if (devNull >= 0)
			dup2(devNull, 2);
		execvp("zenity", (char* const*)argv);
		_exit(127);
	}
	close(fds[1]);
	int len = ReadAllFromPipe(fds[0], outPath, outCap);
	close(fds[0]);
	int status = 0;
	waitpid(pid, &status, 0);
	if (WIFEXITED(status) && WEXITSTATUS(status) == 127)
		return -1;
	while (len > 0 && (outPath[len - 1] == '\n' || outPath[len - 1] == '\r'))
		outPath[--len] = 0;
	return len > 0 ? 1 : 0;
}

#endif

TH_API int th_native_dialog(int pickFolder, const char* initialDir, char* outPath, int outCap)
{
	if (outPath == nullptr || outCap <= 0)
		return -1;
	outPath[0] = 0;
#if defined(_WIN32)
	return NativeDialogWin32(pickFolder, initialDir, outPath, outCap);
#else
	return NativeDialogZenity(pickFolder, initialDir, outPath, outCap);
#endif
}
