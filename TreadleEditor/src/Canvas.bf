using System;
using ImGui;

namespace Treadle.Editor
{
	/// Drawing primitives and maths for the node-graph canvas (UE5 Blueprint look).
	/// Everything here works in screen pixels; callers convert from grid units with the zoom.
	static class Canvas
	{
		/// Unreal's graph zoom steps. Index `DefaultZoomLevel` is 1:1.
		public static float[20] ZoomLevels = .(0.1f, 0.125f, 0.15f, 0.175f, 0.2f, 0.225f, 0.25f, 0.375f, 0.5f, 0.675f,
			0.75f, 0.875f, 1.0f, 1.25f, 1.375f, 1.5f, 1.675f, 1.75f, 1.875f, 2.0f);
		public const int32 DefaultZoomLevel = 12;
		public const float MinorGrid = 16;
		public const float MajorGrid = 128;
		public const float SnapGrid = 16;

		/// "Zoom 1:1", "Zoom -3", "Zoom +2" like UE.
		public static void ZoomLabel(int32 level, String outText)
		{
			int32 d = level - DefaultZoomLevel;
			if (d == 0)
				outText.Append("Zoom 1:1");
			else if (d > 0)
				outText.AppendF("Zoom +{}", d);
			else
				outText.AppendF("Zoom {}", d);
		}

		/// The largest zoom level not above `zoom`.
		public static int32 LevelAtOrBelow(float zoom)
		{
			int32 best = 0;
			for (int32 i < ZoomLevels.Count)
				if (ZoomLevels[i] <= zoom + 0.0001f)
					best = i;
			return best;
		}

		/// The self test: when set, FillRoundedGradient adds the vertices of its transparent outer edge here.
		public static System.Collections.List<ImVec2> SelfTestFringe;

		public static float Snap(float v) =>(float)Math.Round(v / SnapGrid) * SnapGrid;
		/// Snaps when "Snap to Grid" is on (Editor Preferences / toolbar).
		public static float SnapIf(float v) => Prefs.GridSnap ? Snap(v) : v;

		public static void Background(ImDrawList* dl, ImVec2 origin, ImVec2 size, ImVec2 pan, float zoom)
		{
			let max = origin + size;
			Gui.ImDrawList_AddRectFilled(dl, origin, max, Theme.CanvasBg, 0, 0);

			// Minor lines fade out as they get too dense, like UE when zoomed far out.
			float minorPx = MinorGrid * zoom;
			float minorAlpha = Math.Clamp((minorPx - 4.0f) / 8.0f, 0, 1);
			if (minorAlpha > 0)
				GridLines(dl, origin, size, pan, zoom, MinorGrid, Theme.WithAlpha(Theme.GridMinor, (uint8)(255 * minorAlpha)), MajorGrid);
			float majorPx = MajorGrid * zoom;
			float majorAlpha = Math.Clamp((majorPx - 6.0f) / 20.0f, 0, 1);
			if (majorAlpha > 0)
				GridLines(dl, origin, size, pan, zoom, MajorGrid, Theme.WithAlpha(Theme.GridMajor, (uint8)(255 * majorAlpha)), 0);
		}

		/// Grid lines every `step` grid units, skipping multiples of `skipEvery` (drawn by another pass).
		static void GridLines(ImDrawList* dl, ImVec2 origin, ImVec2 size, ImVec2 pan, float zoom, float step, uint32 col, float skipEvery)
		{
			let max = origin + size;
			// First grid line at or left of the visible area: grid x = -pan.x
			float gx0 = (float)Math.Floor(-pan.x / step) * step;
			float gy0 = (float)Math.Floor(-pan.y / step) * step;
			for (float gx = gx0; ; gx += step)
			{
				float sx = origin.x + (gx + pan.x) * zoom;
				if (sx > max.x)
					break;
				if (skipEvery > 0 && Math.Abs(gx - (float)Math.Round(gx / skipEvery) * skipEvery) < 0.01f)
					continue;
				if (sx >= origin.x)
					Gui.ImDrawList_AddLine(dl, .(sx, origin.y), .(sx, max.y), col, 1);
			}
			for (float gy = gy0; ; gy += step)
			{
				float sy = origin.y + (gy + pan.y) * zoom;
				if (sy > max.y)
					break;
				if (skipEvery > 0 && Math.Abs(gy - (float)Math.Round(gy / skipEvery) * skipEvery) < 0.01f)
					continue;
				if (sy >= origin.y)
					Gui.ImDrawList_AddLine(dl, .(origin.x, sy), .(max.x, sy), col, 1);
			}
		}

		[CLink] static extern void ImDrawList_PrimReserve(ImDrawList* self, int32 idxCount, int32 vtxCount);
		[CLink] static extern void ImDrawList_PrimVtx(ImDrawList* self, ImVec2 pos, ImVec2 uv, uint32 col);
		[CLink] static extern ImVec2 igGetFontTexUvWhitePixel();

		static uint32 LerpColor(uint32 a, uint32 b, float t)
		{
			uint32 result = 0;
			for (int32 shift = 0; shift < 32; shift += 8)
			{
				float x = (a >> shift) & 0xFF;
				float y = (b >> shift) & 0xFF;
				uint32 v = (uint32)Math.Clamp((int)(x + (y - x) * t + 0.5f), 0, 255);
				result |= v << shift;
			}
			return result;
		}

		/// A rounded rectangle filled with a horizontal gradient (`colLeft` at its left edge, `colRight` at its
		/// right edge), as ONE anti-aliased mesh. Stacking a gradient quad on rounded end caps leaves a seam where
		/// they meet and quad edges that stick out past the rounded outline, both of which shimmer while zooming;
		/// a single shape has neither. The edge gets the same one-pixel soft fringe the filled shapes of the draw
		/// list have, so it matches the outline drawn over it.
		public static void FillRoundedGradient(ImDrawList* dl, ImVec2 p0, ImVec2 p1, float rounding, uint32 colLeft, uint32 colRight, bool squareBottom = false)
		{
			float w = p1.x - p0.x;
			float h = p1.y - p0.y;
			if (w < 2 || h < 2)
				return;
			float r = Math.Max(0, Math.Min(rounding, Math.Min(w, h) * 0.5f));
			int32 seg = (r < 1) ? 1 : (int32)Math.Clamp((int)Math.Ceiling(r * 0.5f) + 2, 3, 12);
			int32 n = (seg + 1) * 4;
			ImVec2[52] inner = ?;
			ImVec2[52] outer = ?;
			uint32[52] innerCol = ?;
			uint32[52] outerCol = ?;
			// Corner centres, clockwise from the top right; each arc runs a quarter turn. `squareBottom` (a node
			// header) keeps the bottom corners square: their arcs shrink to the corner point.
			float rb = squareBottom ? 0 : r;
			ImVec2[4] centre = .(.(p1.x - r, p0.y + r), .(p1.x - rb, p1.y - rb), .(p0.x + rb, p1.y - rb), .(p0.x + r, p0.y + r));
			float[4] radius = .(r, rb, rb, r);
			float[4] start = .(-Math.PI_f * 0.5f, 0, Math.PI_f * 0.5f, Math.PI_f);
			for (int32 k < 4)
			{
				float rk = radius[k];
				float ri = Math.Max(0, rk - 0.5f);
				float ro = rk + 0.5f;
				for (int32 j <= seg)
				{
					float a = start[k] + (Math.PI_f * 0.5f) * (j / (float)seg);
					float ca = Math.Cos(a);
					float sa = Math.Sin(a);
					int32 i = k * (seg + 1) + j;
					inner[i] = .(centre[k].x + ca * ri, centre[k].y + sa * ri);
					outer[i] = .(centre[k].x + ca * ro, centre[k].y + sa * ro);
					float t = Math.Clamp((centre[k].x + ca * rk - p0.x) / w, 0, 1);
					innerCol[i] = LerpColor(colLeft, colRight, t);
					outerCol[i] = innerCol[i] & 0x00FFFFFF;
					SelfTestFringe?.Add(outer[i]);
				}
			}
			let uv = igGetFontTexUvWhitePixel();
			let mid = ImVec2((p0.x + p1.x) * 0.5f, (p0.y + p1.y) * 0.5f);
			uint32 midCol = LerpColor(colLeft, colRight, 0.5f);
			int32 verts = n * 9;
			ImDrawList_PrimReserve(dl, verts, verts);
			for (int32 i < n)
			{
				int32 j = (i + 1) % n;
				ImDrawList_PrimVtx(dl, mid, uv, midCol);
				ImDrawList_PrimVtx(dl, inner[i], uv, innerCol[i]);
				ImDrawList_PrimVtx(dl, inner[j], uv, innerCol[j]);
				ImDrawList_PrimVtx(dl, inner[i], uv, innerCol[i]);
				ImDrawList_PrimVtx(dl, outer[i], uv, outerCol[i]);
				ImDrawList_PrimVtx(dl, outer[j], uv, outerCol[j]);
				ImDrawList_PrimVtx(dl, inner[i], uv, innerCol[i]);
				ImDrawList_PrimVtx(dl, outer[j], uv, outerCol[j]);
				ImDrawList_PrimVtx(dl, inner[j], uv, innerCol[j]);
			}
		}

		/// A band of diagonal hatch lines (rising to the right, `spacing` apart along x, `thickness` wide)
		/// across the top `bandH` pixels of a rectangle from `p0` to `p1` whose top corners are rounded by
		/// `rounding`. Each line is a strip clipped to the rounded outline, so the hatch runs into the corners
		/// and stops on the outline at every zoom. The outline used is the centre line of the 1-pixel border
		/// the draw list strokes along that shape (half a pixel in), so the strips' soft edge ends where the
		/// shape's own soft edge does; the band's bottom (and the sides) are cut hard by a clip rect, as a
		/// straight edge needs no soft edge. Slivers under a quarter pixel are skipped: an anti-aliased fill
		/// that thin spills a bright fringe. The lines keep their places along x relative to `p0.x`.
		/// `record`: every drawn vertex is added (the self test).
		public static void HatchRoundedTop(ImDrawList* dl, ImVec2 p0, ImVec2 p1, float rounding, float bandH, float spacing, float thickness, uint32 col, System.Collections.List<ImVec2> record = null)
		{
			float w = p1.x - p0.x;
			float hh = Math.Min(bandH, p1.y - p0.y);
			if (w < 2 || hh < 0.5f || spacing < 0.5f)
				return;
			float r = Math.Max(0, Math.Min(rounding, Math.Min(w, p1.y - p0.y) * 0.5f));
			float rc = Math.Max(0, r - 0.5f);
			float y0 = p0.y;
			float y1 = p0.y + hh;
			// The outline, clockwise on screen (y down): up the top-left arc, along the top, down the top-right arc,
			// closed half a pixel under the band (the clip rect cuts there) and never above the arcs' ends, so it
			// stays convex when the band is shallower than the corners.
			int32 seg = (r < 1) ? 1 : (int32)Math.Clamp((int)Math.Ceiling(r * 0.5f) + 2, 3, 12);
			ImVec2[30] clip = ?;
			int32 nc = 0;
			float yb = Math.Max(y1 + 0.5f, p0.y + r);
			clip[nc++] = .(p0.x + r - rc, yb);
			for (int32 k < 2)
			{
				let c = (k == 0) ? ImVec2(p0.x + r, p0.y + r) : ImVec2(p1.x - r, p0.y + r);
				for (int32 j <= seg)
				{
					float ang = Math.PI_f * (1.0f + 0.5f * k) + (Math.PI_f * 0.5f) * (j / (float)seg);
					clip[nc++] = .(c.x + Math.Cos(ang) * rc, c.y + Math.Sin(ang) * rc);
				}
			}
			clip[nc++] = .(p1.x - r + rc, yb);

			float d = thickness * 0.70710678f; // half the strip's width along x
			float x = p0.x - (float)Math.Ceiling((hh + d + 1) / spacing) * spacing;
			ImVec2[40] a = ?;
			ImVec2[40] b = ?;
			Gui.ImDrawList_PushClipRect(dl, p0, .(p1.x, y1), true);
			for (; x - d - 1 < p1.x; x += spacing)
			{
				// The strip of the line from (x, y1) to (x + hh, y0), a pixel longer at both ends, clockwise on screen.
				int32 n = 4;
				a[0] = .(x - d - 1, y1 + 1);
				a[1] = .(x + hh - d + 1, y0 - 1);
				a[2] = .(x + hh + d + 1, y0 - 1);
				a[3] = .(x + d - 1, y1 + 1);
				// Sutherland-Hodgman against each outline edge (inside: right of the edge on screen).
				for (int32 e < nc)
				{
					if (n == 0)
						break;
					let ea = clip[e];
					let eb = clip[(e + 1) % nc];
					int32 m = 0;
					for (int32 i < n)
					{
						let cur = a[i];
						let prev = a[(i + n - 1) % n];
						float sc = (eb.x - ea.x) * (cur.y - ea.y) - (eb.y - ea.y) * (cur.x - ea.x);
						float sp = (eb.x - ea.x) * (prev.y - ea.y) - (eb.y - ea.y) * (prev.x - ea.x);
						if ((sc >= 0) != (sp >= 0))
						{
							float t = sp / (sp - sc);
							b[m++] = .(prev.x + (cur.x - prev.x) * t, prev.y + (cur.y - prev.y) * t);
						}
						if (sc >= 0)
							b[m++] = cur;
					}
					for (int32 i < m)
						a[i] = b[i];
					n = m;
				}
				if (n < 3)
					continue;
				float area = 0;
				for (int32 i < n)
				{
					let q = a[(i + 1) % n];
					area += a[i].x * q.y - q.x * a[i].y;
				}
				if (Math.Abs(area) * 0.5f < 0.25f)
					continue;
				Gui.ImDrawList_AddConvexPolyFilled(dl, &a[0], n, col);
				if (record != null)
					for (int32 i < n)
						record.Add(a[i]);
			}
			Gui.ImDrawList_PopClipRect(dl);
		}

		/// UE's exec pin: a pentagon "arrow house" pointing right. `s` is the half size.
		public static void ExecPin(ImDrawList* dl, ImVec2 c, float s, uint32 col, bool filled, float thickness)
		{
			ImVec2[5] pts = .(
				.(c.x - s * 0.9f, c.y - s),
				.(c.x + s * 0.15f, c.y - s),
				.(c.x + s, c.y),
				.(c.x + s * 0.15f, c.y + s),
				.(c.x - s * 0.9f, c.y + s));
			if (filled)
				Gui.ImDrawList_AddConvexPolyFilled(dl, &pts[0], 5, col);
			else
				Gui.ImDrawList_AddPolyline(dl, &pts[0], 5, col, thickness, DrawFlags.Closed);
		}

		/// UE's data pin: ring when unlinked, filled disc when linked, with a small arrow.
		/// `arrowX` is the x of the arrow's centre (left of inputs, right of outputs).
		public static void DataPin(ImDrawList* dl, ImVec2 c, float r, uint32 col, bool filled, float arrowX, float thickness)
		{
			if (filled)
				Gui.ImDrawList_AddCircleFilled(dl, c, r, col, 0);
			else
				Gui.ImDrawList_AddCircle(dl, c, r - thickness * 0.5f, col, 0, thickness);
			float a = r * 0.55f;
			Gui.ImDrawList_AddTriangleFilled(dl, .(arrowX - a * 0.6f, c.y - a), .(arrowX + a * 0.6f, c.y), .(arrowX - a * 0.6f, c.y + a), col);
		}

		/// Control points of a UE-style wire. Mirrors Unreal's ComputeSplineTangent defaults
		/// (forward: 1x dx + 1x dy clamped to 1000; backward: 3x dx + 1.5x dy clamped to 200),
		/// converted from a Hermite tangent to Bezier control points (tangent / 3).
		public static void WireControls(ImVec2 from, ImVec2 to, float zoom, out ImVec2 c1, out ImVec2 c2)
		{
			float dx = to.x - from.x;
			float dy = Math.Abs(to.y - from.y);
			float t;
			if (dx >= 0)
				t = Math.Min(dx, 1000 * zoom) + Math.Min(dy, 1000 * zoom);
			else
				t = Math.Min(-dx, 200 * zoom) * 3 + Math.Min(dy, 200 * zoom) * 1.5f;
			t = Math.Max(t / 3, 4 * zoom);
			c1 = .(from.x + t, from.y);
			c2 = .(to.x - t, to.y);
		}

		/// False when the wire between two pins cannot touch the rectangle: a Bezier curve stays inside the box of its four
		/// control points, which is widened by `margin` for the line's thickness.
		public static bool WireTouches(ImVec2 from, ImVec2 to, float zoom, ImVec2 rectMin, ImVec2 rectMax, float margin)
		{
			WireControls(from, to, zoom, let c1, let c2);
			float minX = Math.Min(Math.Min(from.x, to.x), Math.Min(c1.x, c2.x)) - margin;
			float maxX = Math.Max(Math.Max(from.x, to.x), Math.Max(c1.x, c2.x)) + margin;
			float minY = Math.Min(from.y, to.y) - margin;
			float maxY = Math.Max(from.y, to.y) + margin;
			return minX < rectMax.x && rectMin.x < maxX && minY < rectMax.y && rectMin.y < maxY;
		}

		public static void Wire(ImDrawList* dl, ImVec2 from, ImVec2 to, float zoom, uint32 col, float thickness)
		{
			WireControls(from, to, zoom, let c1, let c2);
			Gui.ImDrawList_AddBezierCubic(dl, from, c1, c2, to, col, thickness, 0);
		}

		static ImVec2 Bezier(ImVec2 p0, ImVec2 p1, ImVec2 p2, ImVec2 p3, float t)
		{
			float u = 1 - t;
			float w0 = u * u * u;
			float w1 = 3 * u * u * t;
			float w2 = 3 * u * t * t;
			float w3 = t * t * t;
			return .(p0.x * w0 + p1.x * w1 + p2.x * w2 + p3.x * w3, p0.y * w0 + p1.y * w1 + p2.y * w2 + p3.y * w3);
		}

		static float DistToSegment(ImVec2 p, ImVec2 a, ImVec2 b)
		{
			let ab = b - a;
			let ap = p - a;
			float len2 = ab.x * ab.x + ab.y * ab.y;
			float t = (len2 > 0.0001f) ? Math.Clamp((ap.x * ab.x + ap.y * ab.y) / len2, 0, 1) : 0;
			let q = a + ab * t;
			let d = p - q;
			return Math.Sqrt(d.x * d.x + d.y * d.y);
		}

		/// Screen-space distance from `p` to the wire between two pins.
		public static float DistToWire(ImVec2 p, ImVec2 from, ImVec2 to, float zoom)
		{
			// Cheap reject with the curve's bounding box.
			WireControls(from, to, zoom, let c1, let c2);
			float minX = Math.Min(Math.Min(from.x, to.x), Math.Min(c1.x, c2.x)) - 10;
			float maxX = Math.Max(Math.Max(from.x, to.x), Math.Max(c1.x, c2.x)) + 10;
			float minY = Math.Min(from.y, to.y) - 10;
			float maxY = Math.Max(from.y, to.y) + 10;
			if (p.x < minX || p.x > maxX || p.y < minY || p.y > maxY)
				return float.MaxValue;
			float best = float.MaxValue;
			ImVec2 prev = from;
			const int32 Steps = 24;
			for (int32 i = 1; i <= Steps; i++)
			{
				let cur = Bezier(from, c1, c2, to, i / (float)Steps);
				best = Math.Min(best, DistToSegment(p, prev, cur));
				prev = cur;
			}
			return best;
		}

		public static bool RectContains(ImVec2 min, ImVec2 max, ImVec2 p) => p.x >= min.x && p.y >= min.y && p.x < max.x && p.y < max.y;

		public static bool RectsOverlap(ImVec2 aMin, ImVec2 aMax, ImVec2 bMin, ImVec2 bMax) =>
			aMin.x < bMax.x && bMin.x < aMax.x && aMin.y < bMax.y && bMin.y < aMax.y;
	}
}
