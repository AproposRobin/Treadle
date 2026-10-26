using System;
using System.Collections;

namespace Treadle.Editor
{
	/// Where a Sheet frame spends its time, in microseconds: `GraphPanel.Draw` adds the time of each
	/// section while `Enabled` (the `graphux-perf` capture step turns it on and reports the means).
	/// Costs nothing while off.
	static class GraphProf
	{
		public const int Total = 0;
		public const int Prepare = 1;
		public const int Diagnostics = 2;
		public const int Layout = 3;
		public const int Visibility = 4;
		public const int Hover = 5;
		public const int Wires = 6;
		public const int Nodes = 7;
		public const int Overlays = 8;
		public const int Input = 9;
		public const int Count = 10;

		public static bool Enabled;
		/// The perf step treats the held pointer as hovering the canvas, so hit testing is part of the numbers.
		public static bool ForceHover;
		public static double[Count] Frame;
		static double[Count] sMark;

		public static StringView Name(int i)
		{
			switch (i)
			{
			case Total: return "total";
			case Prepare: return "prepare";
			case Diagnostics: return "diagnostics";
			case Layout: return "layout";
			case Visibility: return "visibility";
			case Hover: return "hover";
			case Wires: return "wires";
			case Nodes: return "nodes";
			case Overlays: return "overlays";
			default: return "input";
			}
		}

		public static void Reset()
		{
			for (int i < Count)
				Frame[i] = 0;
		}

		public static void Begin(int section)
		{
			if (Enabled)
				sMark[section] = Desktop.Now;
		}

		public static void End(int section)
		{
			if (Enabled)
				Frame[section] += (Desktop.Now - sMark[section]) * 1000000.0;
		}
	}
}
