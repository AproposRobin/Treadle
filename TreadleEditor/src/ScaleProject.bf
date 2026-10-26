// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;

namespace Treadle.Editor
{
	/// Writes a synthetic project of a given size for the `scale` self test and the scale measurements
	/// (docs/Editor-Model.md, "Scale"): static classes of int arithmetic Sheets calling each other, generic
	/// classes used from them (Construct, Call, Delete), extensions of `Core.List<T>`, delegate types with
	/// event-bearing classes (Bind, Add, Invoke), Local Lambdas with their `lambda:` Sheets, one type holding
	/// one big Sheet, one large type file (`Huge.treadle`, node comments and docs) and a Program whose Main calls
	/// into them. Every Sheet has a layout. The same seed gives the same files.
	class ScaleProject
	{
		public struct Size
		{
			public int Types;
			public int Sheets;
			public int Nodes;
			public int Wires;
			public int BigNodes;
			public int BigWires;
			public int HugeBytes;
		}

		/// The measured size (docs/Editor-Model.md, "Scale").
		public static Size Full = .() { Types = 200, Sheets = 2000, Nodes = 60000, Wires = 80000, BigNodes = 600, BigWires = 1000, HugeBytes = 2000000 };
		/// The `scale` self test's size.
		public static Size Reduced = .() { Types = 20, Sheets = 200, Nodes = 6000, Wires = 8000, BigNodes = 300, BigWires = 500, HugeBytes = 200000 };

		/// What was written.
		public int TypesWritten;
		public int SheetsWritten;
		public int NodesWritten;
		public int WiresWritten;
		public int HugeFileBytes;
		/// The big Sheet: its type file and its Sheet key.
		public String BigPath = new .() ~ delete _;
		public String BigKey = new .() ~ delete _;
		public String HugePath = new .() ~ delete _;

		uint64 mSeed = 0x9E3779B97F4A7C15UL;
		String mRoot = new .() ~ delete _;
		/// Static int(int a, int b) functions other Sheets call: "Scale.T12.F3".
		List<String> mTargets = new .() ~ DeleteContainerAndItems!(_);
		List<String> mBoxes = new .() ~ DeleteContainerAndItems!(_);

		int Next(int n)
		{
			mSeed ^= mSeed << 13;
			mSeed ^= mSeed >> 7;
			mSeed ^= mSeed << 17;
			return (int)(mSeed % (uint64)n);
		}

		/// One type file being written.
		class TypeOut
		{
			public String Text = new .() ~ delete _;
			public String Layout = new .() ~ delete _;
			/// The current member's `lambda:` Sheets (written after its body).
			public String Pending = new .() ~ delete _;
			public String PendingLayout = new .() ~ delete _;
			int mNode;
			int mMember;

			public void NodeId(String outId)
			{
				mNode++;
				outId.Append('n');
				ToBase36(mNode, 5, outId);
			}

			public void MemberId(String outId)
			{
				mMember++;
				outId.AppendF("m{:0000}", mMember);
			}

			static void ToBase36(int v, int width, String outText)
			{
				char8[16] buf = default;
				int n = v;
				for (int i < width)
				{
					let d = n % 36;
					buf[width - 1 - i] = (d < 10) ? (char8)('0' + d) : (char8)('a' + d - 10);
					n /= 36;
				}
				outText.Append(&buf, width);
			}
		}

		/// One Sheet being written: its node records, its wires and its layout lines.
		class SheetOut
		{
			public String Nodes = new .() ~ delete _;
			public String Wires = new .() ~ delete _;
			public String Layout = new .() ~ delete _;
			public int NodeCount;
			public int WireCount;

			public void Node(StringView id, StringView kind, int x, int y)
			{
				Nodes.AppendF("node {} {}\n", id, kind);
				Layout.AppendF("\tnode {} {} {}\n", id, x, y);
				NodeCount++;
			}

			public void Wire(StringView from, StringView to)
			{
				Wires.AppendF("wire {} {}\n", from, to);
				WireCount++;
			}

			public void Flush(StringView key, String text, String layout, StringView textKey = "body")
			{
				// The type file names the Sheet's role, the layout file its owner.
				text.AppendF("sheet {}\n", key.StartsWith("lambda:") ? key : textKey);
				text.Append(Nodes);
				text.Append(Wires);
				layout.AppendF("sheet {}\n", key);
				layout.Append(Layout);
			}
		}

		void Count(SheetOut s)
		{
			SheetsWritten++;
			NodesWritten += s.NodeCount;
			WiresWritten += s.WireCount;
		}

		static void Header(TypeOut t, StringView name, StringView kind, StringView extra)
		{
			t.Text.AppendF("# treadle 1\ntype {} {}\n\tnamespace Scale\n", name, kind);
			t.Text.Append(extra);
			t.Layout.Append("# treadle-layout 1\n");
		}

		void Save(TypeOut t, StringView folder, StringView name, String outPath = null)
		{
			let dir = scope $"{mRoot}/{folder}";
			Directory.CreateDirectory(dir).IgnoreError();
			let path = scope $"{dir}/{name}.treadle";
			File.WriteAllText(path, t.Text).IgnoreError();
			File.WriteAllText(scope $"{path}.layout", t.Layout).IgnoreError();
			outPath?.Set(path);
			TypesWritten++;
		}

		static StringView Words(int i)
		{
			const String[?] words = .("total", "count", "step", "value", "score", "limit", "offset", "weight", "index", "bonus", "range", "speed");
			return words[i % words.Count];
		}

		/// A static `int <name>(int a, int b)` with a body Sheet of about `nodes` nodes and `wires` wires.
		/// `lambdas`: also a Local Lambda (and its Sheet). `self`: the type's own earlier functions are the
		/// call targets (else the project's first `targetLimit`: no call cycles, so Main runs and ends). `comments`: every n-th node has a comment (0: none).
		void Calc(TypeOut t, StringView typeName, StringView name, int nodes, int wires, bool lambdas, bool boxes, int comments = 0, int docBytes = 0, List<String> selfTargets = null, int targetLimit = int.MaxValue)
		{
			let fid = t.MemberId(.. scope String());
			t.Text.AppendF("\nfunction {} {}\n\tstatic\n\treturns int\n", fid, name);
			if (docBytes > 0)
			{
				t.Text.Append("\tdoc \"");
				for (int i = 0; i < docBytes; i += 12)
					t.Text.AppendF("{} {} ", Words(i + nodes), Words(i / 3 + 1));
				t.Text.Append("\"\n");
			}
			t.Text.Append("param a int\nparam b int\nlocal acc int\n");
			SheetOut s = scope .();
			let entry = t.NodeId(.. scope String());
			s.Node(entry, "Entry", 0, 0);
			List<String> pool = scope .();
			defer { ClearAndDeleteItems!(pool); }
			pool.Add(new $"{entry}.a");
			pool.Add(new $"{entry}.b");
			String flow = scope $"{entry}.then";
			int col = 1;
			int row = 0;
			int data = 0;
			bool lambdaDone = !lambdas;
			bool boxDone = !boxes || mBoxes.IsEmpty;
			let budget = Math.Max(nodes, 2);
			int sinceComment = 0;

			void Pick(String outFrom)
			{
				let n = pool.Count;
				let i = (Next(4) == 0) ? Next(n) : Math.Max(0, n - 1 - Next(Math.Min(n, 5)));
				outFrom.Set(pool[i]);
			}
			bool Behind() => s.WireCount < (int)((int64)wires * (s.NodeCount + 1) / budget);
			void Input(StringView node, StringView pin, bool always = false)
			{
				if (always || Behind())
					s.Wire(Pick(.. scope String()), scope $"{node}.{pin}");
				else
					s.Nodes.AppendF("\tin {} {}\n", pin, Next(9) + 1);
			}
			void Comment()
			{
				if (comments > 0 && ++sinceComment >= comments)
				{
					sinceComment = 0;
					s.Nodes.Append("\tcomment \"");
					for (int i < 14)
						s.Nodes.AppendF("{} ", Words(i + s.NodeCount));
					s.Nodes.Append("\"\n");
				}
			}
			// Flow nodes left to right in rows of 16; their data nodes under them.
			void FlowPos(out int x, out int y)
			{
				x = col * 300;
				y = row * 640;
				data = 0;
				if (++col > 16)
				{
					col = 0;
					row++;
				}
			}
			void DataPos(out int x, out int y)
			{
				x = Math.Max(0, col - 1) * 300 - 140 + (data / 4) * 60;
				y = row * 640 + 150 + (data % 4) * 110;
				data++;
			}

			while (s.NodeCount < budget - 1)
			{
				let left = budget - 1 - s.NodeCount;
				let r = Next(100);
				let behind = Behind();
				if (!lambdaDone && left >= 6)
				{
					lambdaDone = true;
					let l = t.NodeId(.. scope String());
					let inv = t.NodeId(.. scope String());
					FlowPos(let lx, let ly);
					s.Node(l, "Lambda", lx, ly);
					s.Nodes.Append("\tset type delegate:int(int)\n\tset alloc local\n\tset inputs x\n");
					FlowPos(let ix, let iy);
					s.Node(inv, "Invoke", ix, iy);
					Input(inv, "arg0");
					s.Wire(flow, scope $"{l}.in");
					s.Wire(scope $"{l}.then", scope $"{inv}.in");
					s.Wire(scope $"{l}.value", scope $"{inv}.delegate");
					flow.Set(scope $"{inv}.then");
					pool.Add(new $"{inv}.result");
					// Its Sheet: x + k.
					SheetOut ls = scope .();
					let e = t.NodeId(.. scope String());
					let o = t.NodeId(.. scope String());
					let ret = t.NodeId(.. scope String());
					ls.Node(e, "Entry", 0, 0);
					ls.Node(o, "Operator +", 260, 120);
					ls.Nodes.AppendF("\tin b {}\n", Next(9) + 1);
					ls.Node(ret, "Return", 520, 0);
					ls.Wire(scope $"{e}.x", scope $"{o}.a");
					ls.Wire(scope $"{e}.then", scope $"{ret}.in");
					ls.Wire(scope $"{o}.result", scope $"{ret}.value");
					ls.Flush(scope $"lambda:{l}", t.Pending, t.PendingLayout);
					Count(ls);
					// The Lambda Sheet's nodes count against this Sheet's budget.
					s.NodeCount += 3;
					s.WireCount += 3;
					continue;
				}
				if (!boxDone && left >= 5)
				{
					boxDone = true;
					let bx = mBoxes[Next(mBoxes.Count)];
					let c = t.NodeId(.. scope String());
					let put = t.NodeId(.. scope String());
					let take = t.NodeId(.. scope String());
					let del = t.NodeId(.. scope String());
					FlowPos(let cx, let cy);
					s.Node(c, scope $"Construct {bx}<int>", cx, cy);
					s.Wire(flow, scope $"{c}.in");
					FlowPos(let px, let py);
					s.Node(put, scope $"Call {bx}<int>.Put", px, py);
					Input(put, "v");
					s.Wire(scope $"{c}.then", scope $"{put}.in");
					s.Wire(scope $"{c}.object", scope $"{put}.receiver");
					FlowPos(let tx, let ty);
					s.Node(take, scope $"Call {bx}<int>.Take", tx, ty);
					s.Wire(scope $"{put}.then", scope $"{take}.in");
					s.Wire(scope $"{c}.object", scope $"{take}.receiver");
					FlowPos(let dx, let dy);
					s.Node(del, "Delete", dx, dy);
					s.Wire(scope $"{take}.then", scope $"{del}.in");
					s.Wire(scope $"{c}.object", scope $"{del}.object");
					flow.Set(scope $"{del}.then");
					pool.Add(new $"{take}.result");
					continue;
				}
				let id = t.NodeId(.. scope String());
				let targets = selfTargets ?? mTargets;
				let targetCount = Math.Min(targets.Count, targetLimit);
				if (r < 34 || (r < 46 && behind))
				{
					const String[?] ops = .("+", "-", "*", "^", "&", "|");
					DataPos(let x, let y);
					s.Node(id, scope $"Operator {ops[Next(ops.Count)]}", x, y);
					Comment();
					Input(id, "a", true);
					Input(id, "b");
					pool.Add(new $"{id}.result");
				}
				else if (r < 46)
				{
					DataPos(let x, let y);
					s.Node(id, "Get local:acc", x, y);
					Comment();
					pool.Add(new $"{id}.value");
				}
				else if (r < 72 || targetCount == 0)
				{
					FlowPos(let x, let y);
					s.Node(id, "Set local:acc", x, y);
					Comment();
					Input(id, "value");
					s.Wire(flow, scope $"{id}.in");
					flow.Set(scope $"{id}.then");
				}
				else
				{
					FlowPos(let x, let y);
					s.Node(id, scope $"Call {targets[Next(targetCount)]}", x, y);
					Comment();
					Input(id, "a");
					Input(id, "b");
					s.Wire(flow, scope $"{id}.in");
					flow.Set(scope $"{id}.then");
					pool.Add(new $"{id}.result");
				}
			}
			let ret = t.NodeId(.. scope String());
			FlowPos(let rx, let ry);
			s.Node(ret, "Return", rx, ry);
			s.Wire(flow, scope $"{ret}.in");
			Input(ret, "value", true);
			s.Flush(fid, t.Text, t.Layout);
			Count(s);
			// The Lambda Sheets' nodes were counted with their own Sheet.
			if (!t.Pending.IsEmpty)
			{
				NodesWritten -= 3;
				WiresWritten -= 3;
			}
			t.Text.Append(t.Pending);
			t.Layout.Append(t.PendingLayout);
			t.Pending.Clear();
			t.PendingLayout.Clear();
			selfTargets?.Add(new $"Scale.{typeName}.{name}");
		}

		/// A generic class: `Put(v)` and `Take()`.
		void Box(StringView name)
		{
			TypeOut t = scope .();
			Header(t, name, "class", "\tgeneric T\n\tdoc \"A generic holder used by the arithmetic types.\"\n\nfield mValue T\n");
			{
				let fid = t.MemberId(.. scope String());
				t.Text.AppendF("\nfunction {} Put\nparam v T\n", fid);
				SheetOut s = scope .();
				let e = t.NodeId(.. scope String());
				let set = t.NodeId(.. scope String());
				let r = t.NodeId(.. scope String());
				s.Node(e, "Entry", 0, 0);
				s.Node(set, "Set this.mValue", 300, 0);
				s.Node(r, "Return", 600, 0);
				s.Wire(scope $"{e}.then", scope $"{set}.in");
				s.Wire(scope $"{e}.v", scope $"{set}.value");
				s.Wire(scope $"{set}.then", scope $"{r}.in");
				s.Flush(fid, t.Text, t.Layout);
				Count(s);
			}
			{
				let fid = t.MemberId(.. scope String());
				t.Text.AppendF("\nfunction {} Take\n\treturns T\n", fid);
				SheetOut s = scope .();
				let e = t.NodeId(.. scope String());
				let g = t.NodeId(.. scope String());
				let r = t.NodeId(.. scope String());
				s.Node(e, "Entry", 0, 0);
				s.Node(g, "Get this.mValue", 300, 140);
				s.Node(r, "Return", 600, 0);
				s.Wire(scope $"{e}.then", scope $"{r}.in");
				s.Wire(scope $"{g}.value", scope $"{r}.value");
				s.Flush(fid, t.Text, t.Layout);
				Count(s);
			}
			Save(t, "Generic", name);
		}

		/// An extension of `Core.List<T>` with two functions named after `n`.
		void Extension(StringView name, int n)
		{
			TypeOut t = scope .();
			Header(t, name, "extension", "\textends Core.List<T>\n");
			{
				let fid = t.MemberId(.. scope String());
				t.Text.AppendF("\nfunction {} CountPlus{}\n\treturns int\nparam extra int\n", fid, n);
				SheetOut s = scope .();
				let e = t.NodeId(.. scope String());
				let g = t.NodeId(.. scope String());
				let o = t.NodeId(.. scope String());
				let r = t.NodeId(.. scope String());
				s.Node(e, "Entry", 0, 0);
				s.Node(g, "Get this.Count", 200, 160);
				s.Node(o, "Operator +", 400, 160);
				s.Node(r, "Return", 600, 0);
				s.Wire(scope $"{g}.value", scope $"{o}.a");
				s.Wire(scope $"{e}.extra", scope $"{o}.b");
				s.Wire(scope $"{e}.then", scope $"{r}.in");
				s.Wire(scope $"{o}.result", scope $"{r}.value");
				s.Flush(fid, t.Text, t.Layout);
				Count(s);
			}
			{
				let fid = t.MemberId(.. scope String());
				t.Text.AppendF("\nfunction {} FirstOr{}\n\treturns T\nparam fallback T\n", fid, n);
				SheetOut s = scope .();
				String[8] ids = default;
				for (int i < 8)
					ids[i] = t.NodeId(.. scope:: String());
				s.Node(ids[0], "Entry", 0, 0);
				s.Node(ids[1], "Get this.Count", 100, 160);
				s.Node(ids[2], "Operator >", 300, 160);
				s.Nodes.Append("\tin b 0\n");
				s.Node(ids[3], "Branch", 300, 0);
				s.Node(ids[4], "This", 500, 200);
				s.Node(ids[5], "Index", 700, 200);
				s.Nodes.Append("\tin index 0\n");
				s.Node(ids[6], "Return", 900, 0);
				s.Node(ids[7], "Return", 900, 300);
				s.Wire(scope $"{ids[1]}.value", scope $"{ids[2]}.a");
				s.Wire(scope $"{ids[2]}.result", scope $"{ids[3]}.condition");
				s.Wire(scope $"{ids[0]}.then", scope $"{ids[3]}.in");
				s.Wire(scope $"{ids[4]}.value", scope $"{ids[5]}.collection");
				s.Wire(scope $"{ids[3]}.true", scope $"{ids[6]}.in");
				s.Wire(scope $"{ids[5]}.value", scope $"{ids[6]}.value");
				s.Wire(scope $"{ids[3]}.false", scope $"{ids[7]}.in");
				s.Wire(scope $"{ids[0]}.fallback", scope $"{ids[7]}.value");
				s.Flush(fid, t.Text, t.Layout);
				Count(s);
			}
			Save(t, "Extensions", name);
		}

		/// A delegate type `Handler<n>` and a class `Emitter<n>` with an event of it: Fire invokes it, Sink is
		/// a handler, Hook makes an Emitter, adds Sink, fires and deletes.
		void Events(int n)
		{
			{
				TypeOut t = scope .();
				Header(t, scope $"Handler{n}", "delegate", "\tsignature void(int)\n");
				Save(t, "Events", scope $"Handler{n}");
			}
			TypeOut t = scope .();
			let name = scope $"Emitter{n}";
			Header(t, name, "class", "\tdoc \"A class with an event.\"\n");
			t.Text.AppendF("\nfield OnFire Scale.Handler{}\n\tattr Event\n", n);
			{
				let fid = t.MemberId(.. scope String());
				t.Text.AppendF("\nfunction {} Fire\nparam x int\n", fid);
				SheetOut s = scope .();
				let e = t.NodeId(.. scope String());
				let c = t.NodeId(.. scope String());
				let r = t.NodeId(.. scope String());
				s.Node(e, "Entry", 0, 0);
				s.Node(c, "Call this.OnFire.Invoke", 300, 0);
				s.Node(r, "Return", 600, 0);
				s.Wire(scope $"{e}.x", scope $"{c}.arg0");
				s.Wire(scope $"{e}.then", scope $"{c}.in");
				s.Wire(scope $"{c}.then", scope $"{r}.in");
				s.Flush(fid, t.Text, t.Layout);
				Count(s);
			}
			{
				let fid = t.MemberId(.. scope String());
				t.Text.AppendF("\nfunction {} Sink\n\tstatic\nparam x int\n", fid);
				SheetOut s = scope .();
				let e = t.NodeId(.. scope String());
				let r = t.NodeId(.. scope String());
				s.Node(e, "Entry", 0, 0);
				s.Node(r, "Return", 300, 0);
				s.Wire(scope $"{e}.then", scope $"{r}.in");
				s.Flush(fid, t.Text, t.Layout);
				Count(s);
			}
			{
				let fid = t.MemberId(.. scope String());
				t.Text.AppendF("\nfunction {} Hook\n\tstatic\n", fid);
				SheetOut s = scope .();
				String[7] ids = default;
				for (int i < 7)
					ids[i] = t.NodeId(.. scope:: String());
				s.Node(ids[0], "Entry", 0, 0);
				s.Node(ids[1], scope $"Construct Scale.{name}", 300, 0);
				s.Node(ids[2], scope $"Bind Scale.{name}.Sink", 600, 0);
				s.Nodes.Append("\tset alloc construct\n");
				s.Node(ids[3], scope $"Call Scale.{name}.OnFire.Add", 900, 0);
				s.Node(ids[4], scope $"Call Scale.{name}.Fire", 1200, 0);
				s.Nodes.AppendF("\tin x {}\n", n);
				s.Node(ids[5], "Delete", 1500, 0);
				s.Node(ids[6], "Return", 1800, 0);
				s.Wire(scope $"{ids[0]}.then", scope $"{ids[1]}.in");
				s.Wire(scope $"{ids[1]}.then", scope $"{ids[2]}.in");
				s.Wire(scope $"{ids[2]}.value", scope $"{ids[3]}.handler");
				s.Wire(scope $"{ids[2]}.then", scope $"{ids[3]}.in");
				s.Wire(scope $"{ids[1]}.object", scope $"{ids[3]}.receiver");
				s.Wire(scope $"{ids[3]}.then", scope $"{ids[4]}.in");
				s.Wire(scope $"{ids[1]}.object", scope $"{ids[4]}.receiver");
				s.Wire(scope $"{ids[4]}.then", scope $"{ids[5]}.in");
				s.Wire(scope $"{ids[1]}.object", scope $"{ids[5]}.object");
				s.Wire(scope $"{ids[5]}.then", scope $"{ids[6]}.in");
				s.Flush(fid, t.Text, t.Layout);
				Count(s);
			}
			Save(t, "Events", name);
		}

		/// Writes the project into `root` (created; files already there are overwritten).
		public void Write(StringView root, Size size)
		{
			mRoot.Set(root);
			Directory.CreateDirectory(root).IgnoreError();
			File.WriteAllText(scope $"{root}/Scale.tproj", "# tproj 1\nproject Scale\n\tkind console\n\tentry Scale.Program\n\tversion 0.1.0\nconfig Debug\n\tchecks on\n\toptimize 0\nconfig Release\n\toptimize 2\n\tchecks off\n").IgnoreError();
			// Inputs that must be wired (flow, Return) push the total a little over the asked ratio.
			let ratio = (float)size.Wires / size.Nodes * 0.95f;
			let groups = Math.Max(1, size.Types / 20);

			// The large file first: its functions call each other only.
			{
				TypeOut t = scope .();
				Header(t, "Huge", "class", "\tstatic\n\tdoc \"One large type file: many Sheets with commented nodes.\"\n");
				List<String> own = scope .();
				defer { ClearAndDeleteItems!(own); }
				int k = 0;
				while (t.Text.Length < size.HugeBytes)
				{
					Calc(t, "Huge", scope $"H{k}", 80, (int)(80 * ratio), (k % 10) == 3, false, 2, 400, own);
					k++;
				}
				Save(t, "Huge", "Huge", HugePath);
				HugeFileBytes = t.Text.Length;
			}
			for (int i < groups)
			{
				let name = scope $"Box{i}";
				Box(name);
				mBoxes.Add(new $"Scale.{name}");
				Extension(scope $"ListExt{i}", i);
				Events(i);
			}
			// What is left for the arithmetic types (Program and the big Sheet's type count as two).
			let calcTypes = Math.Max(1, size.Types - TypesWritten - 2);
			let calcSheets = Math.Max(calcTypes, size.Sheets - SheetsWritten - 2);
			let lambdaSheets = calcSheets / 20;
			let functions = calcSheets - lambdaSheets;
			let nodesLeft = size.Nodes - NodesWritten - size.BigNodes - 3;
			let perSheet = Math.Max(4, nodesLeft / functions);
			// Plan the names first: every arithmetic function is a call target.
			List<int> perType = scope .();
			for (int i < calcTypes)
				perType.Add(functions / calcTypes + ((i < functions % calcTypes) ? 1 : 0));
			for (int i < calcTypes)
				for (int f < perType[i])
					mTargets.Add(new $"Scale.T{i}.F{f}");
			int lambdaEvery = (lambdaSheets > 0) ? Math.Max(1, functions / lambdaSheets) : int.MaxValue;
			int fn = 0;
			let nodesBefore = NodesWritten;
			for (int i < calcTypes)
			{
				TypeOut t = scope .();
				let name = scope $"T{i}";
				Header(t, name, "class", scope $"\tstatic\n\tdoc \"Arithmetic helpers, group {i % groups}.\"\n");
				t.Text.Append("\nfield sCalls int\n\tstatic\n");
				for (int f < perType[i])
				{
					// Sizes spread from half to one and a half times the mean; the last ones absorb the rest.
					let remaining = functions - fn;
					let target = (remaining <= 1) ? Math.Max(4, nodesLeft - (NodesWritten - nodesBefore)) : perSheet / 2 + Next(perSheet + 1);
					Calc(t, name, scope $"F{f}", target, (int)(target * ratio), (fn % lambdaEvery) == lambdaEvery / 2 && lambdaSheets > 0, (fn % 7) == 2, 0, 0, null, fn);
					fn++;
				}
				Save(t, scope $"Group{i % groups:00}", name);
			}
			// The big Sheet.
			{
				TypeOut t = scope .();
				Header(t, "BigSheet", "class", "\tstatic\n\tdoc \"One big Sheet.\"\n");
				Calc(t, "BigSheet", "Big", size.BigNodes, size.BigWires, true, true);
				Save(t, "Huge", "BigSheet", BigPath);
				BigKey.Set("m0001");
			}
			// Program.Main calls the first function of each arithmetic type.
			{
				TypeOut t = scope .();
				Header(t, "Program", "class", "\tstatic\n");
				let fid = t.MemberId(.. scope String());
				t.Text.AppendF("\nfunction {} Main\n\tstatic\n\treturns int\n", fid);
				SheetOut s = scope .();
				let e = t.NodeId(.. scope String());
				let c = t.NodeId(.. scope String());
				let w = t.NodeId(.. scope String());
				let r = t.NodeId(.. scope String());
				s.Node(e, "Entry", 0, 0);
				s.Node(c, "Call Scale.T0.F0", 300, 0);
				s.Nodes.Append("\tin a 1\n\tin b 2\n");
				s.Node(w, "Call Console.WriteLine(int)", 600, 0);
				s.Node(r, "Return", 900, 0);
				s.Nodes.Append("\tin value 0\n");
				s.Wire(scope $"{e}.then", scope $"{c}.in");
				s.Wire(scope $"{c}.then", scope $"{w}.in");
				s.Wire(scope $"{c}.result", scope $"{w}.value");
				s.Wire(scope $"{w}.then", scope $"{r}.in");
				s.Flush(fid, t.Text, t.Layout);
				Count(s);
				Save(t, ".", "Program");
			}
		}
	}
}
#endif
