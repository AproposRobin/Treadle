using System;

namespace ImGui
{
	struct ImNodesEditorContext;

	static class NodesCol
	{
		public const int32 NodeBackground = 0;
		public const int32 NodeBackgroundHovered = 1;
		public const int32 NodeBackgroundSelected = 2;
		public const int32 NodeOutline = 3;
		public const int32 TitleBar = 4;
		public const int32 TitleBarHovered = 5;
		public const int32 TitleBarSelected = 6;
		public const int32 Link = 7;
		public const int32 LinkHovered = 8;
		public const int32 LinkSelected = 9;
		public const int32 Pin = 10;
		public const int32 PinHovered = 11;
	}

	static class PinShape
	{
		public const int32 Circle = 0;
		public const int32 CircleFilled = 1;
		public const int32 Triangle = 2;
		public const int32 TriangleFilled = 3;
		public const int32 Quad = 4;
		public const int32 QuadFilled = 5;
	}

	static class NodesStyleVar
	{
		public const int32 NodePadding = 2;
		public const int32 NodeBorderThickness = 3;
	}

	static class MiniMapLocation
	{
		public const int32 BottomLeft = 0;
		public const int32 BottomRight = 1;
		public const int32 TopLeft = 2;
		public const int32 TopRight = 3;
	}

	static class AttributeFlags
	{
		public const int32 None = 0;
		public const int32 EnableLinkDetachWithDragClick = 1 << 0;
		public const int32 EnableLinkCreationOnSnap = 1 << 1;
	}

	/// Bindings for imnodes (via cimnodes).
	static class ImNodes
	{
		[CLink] public static extern ImNodesEditorContext* imnodes_EditorContextCreate();
		[CLink] public static extern void imnodes_EditorContextFree(ImNodesEditorContext* ctx);
		[CLink] public static extern void imnodes_EditorContextSet(ImNodesEditorContext* ctx);
		[CLink] public static extern ImVec2 imnodes_EditorContextGetPanning();
		[CLink] public static extern void imnodes_EditorContextResetPanning(ImVec2 pos);
		[CLink] public static extern void imnodes_EditorContextMoveToNode(int32 node_id);
		[CLink] public static extern void imnodes_BeginNodeEditor();
		[CLink] public static extern void imnodes_EndNodeEditor();
		[CLink] public static extern void imnodes_MiniMap(float fraction, int32 location, void* callback, void* data);
		[CLink] public static extern void imnodes_PushColorStyle(int32 item, uint32 color);
		[CLink] public static extern void imnodes_PopColorStyle();
		[CLink] public static extern void imnodes_PushStyleVar_Float(int32 item, float value);
		[CLink] public static extern void imnodes_PushStyleVar_Vec2(int32 item, ImVec2 value);
		[CLink] public static extern void imnodes_PopStyleVar(int32 count);
		[CLink] public static extern void imnodes_BeginNode(int32 id);
		[CLink] public static extern void imnodes_EndNode();
		[CLink] public static extern ImVec2 imnodes_GetNodeDimensions(int32 id);
		[CLink] public static extern void imnodes_BeginNodeTitleBar();
		[CLink] public static extern void imnodes_EndNodeTitleBar();
		[CLink] public static extern void imnodes_BeginInputAttribute(int32 id, int32 shape);
		[CLink] public static extern void imnodes_EndInputAttribute();
		[CLink] public static extern void imnodes_BeginOutputAttribute(int32 id, int32 shape);
		[CLink] public static extern void imnodes_EndOutputAttribute();
		[CLink] public static extern void imnodes_BeginStaticAttribute(int32 id);
		[CLink] public static extern void imnodes_EndStaticAttribute();
		[CLink] public static extern void imnodes_PushAttributeFlag(int32 flag);
		[CLink] public static extern void imnodes_PopAttributeFlag();
		[CLink] public static extern void imnodes_Link(int32 id, int32 start_attr, int32 end_attr);
		[CLink] public static extern void imnodes_SetNodeGridSpacePos(int32 node_id, ImVec2 pos);
		[CLink] public static extern ImVec2 imnodes_GetNodeGridSpacePos(int32 node_id);
		[CLink] public static extern ImVec2 imnodes_GetNodeScreenSpacePos(int32 node_id);
		[CLink] public static extern bool imnodes_IsEditorHovered();
		[CLink] public static extern bool imnodes_IsNodeHovered(int32* node_id);
		[CLink] public static extern bool imnodes_IsLinkHovered(int32* link_id);
		[CLink] public static extern bool imnodes_IsPinHovered(int32* attr_id);
		[CLink] public static extern int32 imnodes_NumSelectedNodes();
		[CLink] public static extern int32 imnodes_NumSelectedLinks();
		[CLink] public static extern void imnodes_GetSelectedNodes(int32* node_ids);
		[CLink] public static extern void imnodes_GetSelectedLinks(int32* link_ids);
		[CLink] public static extern void imnodes_ClearNodeSelection_Nil();
		[CLink] public static extern void imnodes_ClearLinkSelection_Nil();
		[CLink] public static extern void imnodes_SelectNode(int32 node_id);
		[CLink] public static extern bool imnodes_IsNodeSelected(int32 node_id);
		[CLink] public static extern bool imnodes_IsAnyAttributeActive(int32* attr_id);
		[CLink] public static extern bool imnodes_IsLinkStarted(int32* started_at);
		[CLink] public static extern bool imnodes_IsLinkDropped(int32* started_at, bool including_detached);
		[CLink] public static extern bool imnodes_IsLinkCreated_BoolPtr(int32* start_attr, int32* end_attr, bool* from_snap);
		[CLink] public static extern bool imnodes_IsLinkDestroyed(int32* link_id);
	}

	/// The native host: window, GL context and ImGui/imnodes contexts.
	static class Host
	{
		/// Where the editor's session log is; the start-up failure message names it. Call before th_init.
		[CLink] public static extern void th_set_log_path(char8* path);
		/// Creates the window and the graphics context. 0 on failure: the host has then shown a message box
		/// (not when TREADLE_NO_START_DIALOG=1) and released what it made; th_last_error says why.
		[CLink] public static extern int32 th_init(char8* title, int32 width, int32 height);
		/// Why the last th_init failed.
		[CLink] public static extern char8* th_last_error();
		[CLink] public static extern int32 th_begin_frame();
		[CLink] public static extern void th_end_frame();
		[CLink] public static extern void th_cancel_quit();
		[CLink] public static extern void th_set_title(char8* title);
		/// The next dropped file (oldest first), null when none is waiting: call until null.
		[CLink] public static extern char8* th_poll_drop();
		[CLink] public static extern ImFont* th_get_mono_font();
		[CLink] public static extern void th_shutdown();
		/// 1 = chosen, 0 = cancelled, -1 = no native dialog available
		[CLink] public static extern int32 th_native_dialog(int32 pickFolder, char8* initialDir, char8* outPath, int32 outCap);
		/// UI scale of the window's display (TREADLE_UI_SCALE / GDK_SCALE off Windows; 1.0 = 96 dpi).
		[CLink] public static extern float th_get_window_scale();
		/// Does nothing for a quiet window (th_set_window_quiet).
		[CLink] public static extern void th_raise_window();
		/// Quiet window for test and capture runs (off-screen, no taskbar button, never activated or raised, still
		/// rendered): 1 = quiet, 0 = normal. Call before th_init; without the call TREADLE_WINDOW_HIDDEN=1 decides.
		[CLink] public static extern void th_set_window_quiet(int32 quiet);
		/// 1 when th_init made a quiet window.
		[CLink] public static extern int32 th_window_quiet();
		/// SDL_WindowFlags of the window (0x40 minimized, 0x200 input focus).
		[CLink] public static extern uint32 th_window_flags();
		/// Handler for host asserts (IM_ASSERT, SDL's). Pass a `function void(char8* expr, char8* file, int32 line)`
		/// cast to void*; it must not block (no dialog). NULL restores the stderr line. Export count +1 (treadlehost.dll).
		[CLink] public static extern void th_set_assert_handler(void* handler);

		// The graphics device (host 1.2.0.0): a lost or no longer current context is found every frame and rebuilt.
		/// Handler for the host's "[gl] ..." lines (a `function void(char8* line)` cast to void*). Before th_init.
		[CLink] public static extern void th_set_log_handler(void* handler);
		/// The last device check: 0 ok, 1 context not current, 2 reset, 3 GL_CONTEXT_LOST, 4 swaps failing, 5 no renderer,
		/// 6 device reset event, 7 could not be restored, 8 not started. Safe from any thread.
		[CLink] public static extern int32 th_gl_check();
		[CLink] public static extern char8* th_gl_check_name(int32 check);
		/// The last and the longest buffer swap (ms). Safe from any thread.
		[CLink] public static extern int32 th_gl_last_swap_ms();
		[CLink] public static extern int32 th_gl_max_swap_ms();
		/// 1 after three failed rebuilds: nothing is drawn until a restore works.
		[CLink] public static extern int32 th_gl_failed();
		/// +1 per rebuild: textures made under an older generation are gone.
		[CLink] public static extern int32 th_gl_generation();
		[CLink] public static extern int32 th_gl_rebuilds();
		[CLink] public static extern int32 th_gl_window_recreates();
		/// Rebuilds the drawing side at the start of the next frame (Window > Restore Graphics).
		[CLink] public static extern void th_gl_request_restore(char8* why);
		/// Self tests: 1 delete the context behind the host, 2 report a reset, 3 = 1 + three failed creations, 4 = 1 + six.
		[CLink] public static extern void th_gl_simulate(int32 mode);
		[CLink] public static extern void th_gl_probe_request();
		/// 0 not read yet, 1 read (rgba: R in the low byte), 2 failed.
		[CLink] public static extern int32 th_gl_probe_result(uint32* rgba);
		[CLink] public static extern void th_push_window_event(int32 windowEvent);
		[CLink] public static extern void th_soak_stats(SoakStats* stats);
		[CLink] public static extern int32 th_last_vtx_count();
		[CLink] public static extern int32 th_gl_present_armed();
		[CLink] public static extern int64 th_gl_swaps();
		[CLink] public static extern int64 th_gl_present_hits();
		[CLink] public static extern int64 th_gl_present_misses();
		[CLink] public static extern char8* th_gl_last_sdl_error();
	}

	/// th_soak_stats (-1 = not available).
	[CRepr]
	struct SoakStats
	{
		public int64 PrivateBytes;
		public int64 GpuProcessBytes;
		public int64 GpuAvailableKb;
		public int32 LiveTextures;
		public int32 LiveBuffers;
		public int32 LiveVertexArrays;
		public int32 LivePrograms;
		public int32 LiveShaders;
		public int32 HighestName;
		public int32 ImGuiTextures;
		public int32 AtlasWidth;
		public int32 AtlasHeight;
		public int32 BakedFonts;
		public int32 Frames;
	}
}
