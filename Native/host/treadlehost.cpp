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
#include "imnodes.h"
namespace ImNodes = IMNODES_NAMESPACE;

#include <SDL.h>
#include <SDL_opengl.h>
#include <SDL_syswm.h>
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
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
#else
	const char* glslVersion = "#version 130";
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
	{
		// The Treadle icon on the title bar, the taskbar and Alt+Tab (Windows), and in X11 / Wayland shells.
		SDL_Surface* icon = SDL_CreateRGBSurfaceWithFormatFrom((void*)kTreadleIconRGBA, kTreadleIconWidth, kTreadleIconHeight, 32,
			kTreadleIconWidth * 4, SDL_PIXELFORMAT_ABGR8888);
		if (icon != nullptr)
		{
			SDL_SetWindowIcon(gWindow, icon);
			SDL_FreeSurface(icon);
		}
	}
	if (gQuiet)
	{
#if defined(_WIN32)
		SDL_SysWMinfo wm;
		SDL_VERSION(&wm.version);
		if (SDL_GetWindowWMInfo(gWindow, &wm) && wm.subsystem == SDL_SYSWM_WINDOWS)
		{
			HWND hwnd = wm.info.win.window;
			LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
			SetWindowLongPtrW(hwnd, GWL_EXSTYLE, (ex | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW) & ~(LONG_PTR)WS_EX_APPWINDOW);
			SetWindowPos(hwnd, HWND_BOTTOM, posX, posY, 0, 0,
				SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
			ShowWindow(hwnd, SW_SHOWNOACTIVATE);
		}
		else
			SDL_ShowWindow(gWindow);
#else
		SDL_ShowWindow(gWindow);
		SDL_SetWindowPosition(gWindow, posX, posY); // a window manager may have placed it on map
#endif
	}
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
	gGLContext = SDL_GL_CreateContext(gWindow);
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
	return 1;
}

// Pumps events and starts an ImGui frame. Returns 0 once the user closed the window.
TH_API int th_begin_frame()
{
	SDL_Event event;
	while (SDL_PollEvent(&event))
	{
		ImGui_ImplSDL2_ProcessEvent(&event);
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

TH_API void th_end_frame()
{
	ImGui::Render();
	ImGuiIO& io = ImGui::GetIO();
	int fbW = (int)(io.DisplaySize.x * io.DisplayFramebufferScale.x);
	int fbH = (int)(io.DisplaySize.y * io.DisplayFramebufferScale.y);
	glViewport(0, 0, fbW, fbH);
	glClearColor(0.08f, 0.08f, 0.08f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
	ServeCaptureRequest(fbW, fbH);
	SDL_GL_SwapWindow(gWindow);
}

// Cancels a pending quit (e.g. "unsaved changes" prompt).
TH_API void th_cancel_quit() { gQuitRequested = false; }

TH_API void th_set_title(const char* title)
{
	if (gWindow != nullptr)
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
	ImGui_ImplOpenGL3_Shutdown();
	ImGui_ImplSDL2_Shutdown();
	ImNodes::DestroyContext();
	ImGui::DestroyContext();
	if (gGLContext != nullptr)
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
static bool ReadDialogResult(IFileOpenDialog* dlg, char* outPath, int outCap)
{
	bool ok = false;
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

static void ConfigureDialog(IFileOpenDialog* dlg, int pickFolder)
{
	DWORD opts = 0;
	dlg->GetOptions(&opts);
	opts |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
	opts |= pickFolder ? FOS_PICKFOLDERS : FOS_FILEMUSTEXIST;
	dlg->SetOptions(opts);
	if (pickFolder)
		dlg->SetTitle(L"Open Beef Project Folder");
	else
	{
		COMDLG_FILTERSPEC filters[] = { { L"Beef Source (*.bf)", L"*.bf" }, { L"All Files", L"*.*" } };
		dlg->SetFileTypes(2, filters);
		dlg->SetTitle(L"Open Beef File");
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
		result = (SUCCEEDED(dlg->Show(OwnerWindow())) && ReadDialogResult(dlg, outPath, outCap)) ? 1 : 0;
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
	const char* argv[8];
	int argc = 0;
	argv[argc++] = "zenity";
	argv[argc++] = "--file-selection";
	if (pickFolder)
		argv[argc++] = "--directory";
	else
	{
		argv[argc++] = "--file-filter=Beef source | *.bf";
		argv[argc++] = "--file-filter=All files | *";
	}
	if (filenameArg[0] != 0)
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
