using System;
using System.Collections;
using Treadle.Update;

namespace Treadle.Debug.Dap
{
	/// What Locals, Evaluate and the pin bubbles show for a value (docs/Debugging.md, "Variables"):
	/// a String as its text, a StringView likewise, `List<T>` as `[a, b, c] (n)` and
	/// `Dictionary<K,V>` as `{k: v, ...} (n)` expanding to their elements, an array as `[..] (n)`,
	/// payload enums as `Some(x)` / `None` / `Ok(x)` / `Err(e)` / `Case(a, b)`, a nullable as its value
	/// or `null`, a tuple as `(a, b)`, a delegate as `Type.Function` or `Lambda <node>`, an object as
	/// `Type (0x..)` with its fields on expand. Containers and strings are read from the program's
	/// memory (DAP readMemory) with the layouts of docs/Compiler.md 5; the rest from lldb's values,
	/// whose types the back end's DWARF describes (Compiler.md 7).
	extension LldbDapAdapter
	{
		enum SynthKind
		{
			None,
			List,
			Dictionary,
			Array
		}

		/// The children of a container, made by the adapter (refs from cSynthBase up).
		class SynthNode
		{
			public SynthKind Kind;
			public uint64 Addr;
			/// The container's type (`Core.List<Core.String>`, `int[]`).
			public String Type = new .() ~ delete _;
			/// An lldb variable path to the container (`counts`), "" when there is none (a pin).
			public String Path = new .() ~ delete _;
			public int64 FrameId;
		}

		const int64 cSynthBase = 0x4000000000;
		/// Elements in a one-line summary.
		const int cPreview = 8;
		/// Elements listed when a container is expanded.
		const int cMaxChildren = 500;
		/// Bytes of text in a summary.
		const int cMaxText = 200;

		void ClearSynth()
		{
			for (let n in mSynth.Values)
				delete n;
			mSynth.Clear();
			mRefFrame.Clear();
		}

		int64 NewSynth(SynthKind kind, uint64 addr, StringView type, StringView path)
		{
			SynthNode n = new .();
			n.Kind = kind;
			n.Addr = addr;
			n.Type.Set(type);
			n.Path.Set(path);
			n.FrameId = mCurFrameId;
			let r = mNextSynth++;
			mSynth[r] = n;
			return r;
		}

		// ------------------------------------------------------------------ types

		/// `Core.List<Core.String>` with the prefix `Core.List` -> its arguments.
		static bool GenericArgs(StringView type, StringView prefix, List<StringView> outArgs)
		{
			if (!type.StartsWith(prefix) || type.Length <= prefix.Length + 1 || type[prefix.Length] != '<' || !type.EndsWith('>'))
				return false;
			let inner = type.Substring(prefix.Length + 1, type.Length - prefix.Length - 2);
			int depth = 0;
			int start = 0;
			for (int i < inner.Length)
			{
				let c = inner[i];
				if (c == '<' || c == '(' || c == '[')
					depth++;
				else if (c == '>' || c == ')' || c == ']')
					depth--;
				else if (c == ',' && depth == 0)
				{
					var a = inner.Substring(start, i - start);
					a.Trim();
					outArgs.Add(a);
					start = i + 1;
				}
			}
			var last = inner.Substring(start);
			last.Trim();
			outArgs.Add(last);
			return true;
		}

		/// A type whose values are references to objects (classes, interfaces, String, the core's
		/// collections, arrays, delegates, closures).
		bool IsReference(StringView type)
		{
			if (type.EndsWith("[]") || type.StartsWith("delegate ") || type.Contains("$lambda_"))
				return true;
			if (type.StartsWith("Core."))
			{
				var name = type.Substring(5);
				let lt = name.IndexOf('<');
				if (lt > 0)
					name = name.Substring(0, lt);
				switch (name)
				{
				case "DictionaryEnumerator", "ListEnumerator", "Option", "Result", "Span", "StringView":
					return false;
				default:
					return true;
				}
			}
			using (mLock.Enter())
				return mProgram != null && mProgram.IsClass(type);
		}

		/// The size of a value of `type` in an array, -1 when the adapter does not know it (a struct,
		/// an enum, a tuple, a nullable: those are read through lldb when a path to them exists).
		int ValueSize(StringView type)
		{
			switch (type)
			{
			case "int", "int64", "uint", "uint64", "isize", "usize", "double":
				return 8;
			case "int32", "uint32", "char32", "float":
				return 4;
			case "int16", "uint16":
				return 2;
			case "int8", "uint8", "bool", "char8":
				return 1;
			case "StringView", "Core.StringView":
				return 16;
			}
			if (type.EndsWith("*") || type.StartsWith("function ") || IsReference(type))
				return 8;
			return -1;
		}

		// ------------------------------------------------------------------ memory

		static uint64 UN(List<uint8> b, int off, int n)
		{
			uint64 v = 0;
			for (int i < n)
				if (off + i < b.Count)
					v |= (uint64)b[off + i] << (8 * i);
			return v;
		}

		static void AppendChar(char32 c, String outText)
		{
			if (c >= (char32)0x20 && c < (char32)0x7F)
				outText.AppendF("'{}'", (char8)c);
			else
				outText.AppendF("U+{:X4}", (uint32)c);
		}

		/// UTF-8 bytes as a quoted text (escapes for quotes and control characters).
		static void Quote(List<uint8> bytes, bool truncated, String outText)
		{
			outText.Append('"');
			for (let b in bytes)
			{
				switch (b)
				{
				case (uint8)'"': outText.Append("\\\"");
				case (uint8)'\\': outText.Append("\\\\");
				case (uint8)'\n': outText.Append("\\n");
				case (uint8)'\r': outText.Append("\\r");
				case (uint8)'\t': outText.Append("\\t");
				default:
					if (b < 0x20)
						outText.AppendF("\\x{:X2}", b);
					else
						outText.Append((char8)b);
				}
			}
			if (truncated)
				outText.Append("...");
			outText.Append('"');
		}

		/// `length` bytes of text at `ptr`, quoted.
		void TextAt(uint64 ptr, int64 length, String outText)
		{
			if (ptr == 0 || length <= 0)
			{
				outText.Append("\"\"");
				return;
			}
			let n = (int)Math.Min(length, cMaxText);
			List<uint8> bytes = scope .();
			if (!ReadMemory(ptr, n, bytes) || bytes.Count < n)
			{
				outText.AppendF("<unreadable text at 0x{:X}>", ptr);
				return;
			}
			Quote(bytes, length > n, outText);
		}

		/// The type name of the object at `addr` (vtable -> TypeInfo -> name), cached per vtable;
		/// "" when it cannot be read, "(not constructed yet)" for a zero vtable.
		void ObjectType(uint64 addr, String outName)
		{
			uint64 vt = 0;
			if (!ReadPtr(addr, out vt))
				return;
			if (vt == 0)
			{
				outName.Set("(not constructed yet)");
				return;
			}
			if (mVtNames.TryGetValue(vt, let known))
			{
				outName.Set(known);
				return;
			}
			String name = scope .();
			uint64 ti = 0, np = 0;
			if (ReadPtr(vt, out ti) && ti != 0 && ReadPtr(ti + 24, out np) && np != 0)
			{
				List<uint8> bytes = scope .();
				if (ReadMemory(np, 128, bytes))
				{
					for (let b in bytes)
					{
						if (b == 0)
							break;
						if (b < 0x20 || b > 0x7E)
						{
							name.Clear();
							break;
						}
						name.Append((char8)b);
					}
				}
			}
			mVtNames[vt] = new String(name);
			outName.Set(name);
		}

		/// The function at `fn` by its Treadle name (`Zoo.Program.Twice`, `Lambda c2`), from lldb's
		/// symbol lookup; cached.
		void FunctionName(uint64 fn, String outName)
		{
			if (fn == 0)
			{
				outName.Set("null");
				return;
			}
			if (mFnNames.TryGetValue(fn, let known))
			{
				outName.Set(known);
				return;
			}
			String name = scope .();
			let r = Request("evaluate", scope $"{{\"expression\":\"`image lookup -a 0x{fn:X}\",\"context\":\"repl\"}}");
			String text = scope .();
			r?.Get("body")?.GetString("result", text);
			delete r;
			let at = text.IndexOf("Summary: ");
			if (at >= 0)
			{
				var line = StringView(text, at + 9);
				let nl = line.IndexOf('\n');
				if (nl >= 0)
					line = line.Substring(0, nl);
				let tick = line.IndexOf('`');
				if (tick >= 0)
					line = line.Substring(tick + 1);
				// cut the parameter list (and ` at file:line`, ` + offset`)
				let paren = line.IndexOf('(');
				if (paren > 0)
					line = line.Substring(0, paren);
				let sp = line.IndexOf(' ');
				if (sp > 0)
					line = line.Substring(0, sp);
				name.Append(line);
				name.Replace("::", ".");
			}
			let lam = name.IndexOf("$lambda_");
			if (lam >= 0)
			{
				var node = StringView(name, lam + 8);
				let dot = node.IndexOf('.');
				if (dot >= 0)
					node = node.Substring(0, dot);
				name.Set(scope $"Lambda {node}");
			}
			if (name.IsEmpty)
				name.AppendF("0x{:X}", fn);
			mFnNames[fn] = new String(name);
			outName.Set(name);
		}

		// ------------------------------------------------------------------ summaries from memory

		/// A value of `type` from `b` at `off` (an element, a key or a value of a container).
		void FormatBytes(StringView type, List<uint8> b, int off, int depth, String outText, SynthKind* outKind = null, uint64* outAddr = null, String outDyn = null)
		{
			switch (type)
			{
			case "int", "int64", "isize": outText.AppendF("{}", (int64)UN(b, off, 8));
			case "uint", "uint64", "usize": outText.AppendF("{}", UN(b, off, 8));
			case "int32": outText.AppendF("{}", (int32)(uint32)UN(b, off, 4));
			case "uint32": outText.AppendF("{}", (uint32)UN(b, off, 4));
			case "int16": outText.AppendF("{}", (int16)(uint16)UN(b, off, 2));
			case "uint16": outText.AppendF("{}", (uint16)UN(b, off, 2));
			case "int8": outText.AppendF("{}", (int8)(uint8)UN(b, off, 1));
			case "uint8": outText.AppendF("{}", (uint8)UN(b, off, 1));
			case "bool": outText.Append((UN(b, off, 1) != 0) ? "true" : "false");
			case "char8": AppendChar((char32)UN(b, off, 1), outText);
			case "char32": AppendChar((char32)UN(b, off, 4), outText);
			case "float":
				uint32 fbits = (uint32)UN(b, off, 4);
				outText.AppendF("{}", *(float*)&fbits);
			case "double":
				uint64 dbits = UN(b, off, 8);
				outText.AppendF("{}", *(double*)&dbits);
			case "StringView", "Core.StringView":
				TextAt(UN(b, off, 8), (int64)UN(b, off + 8, 8), outText);
			default:
				let p = UN(b, off, 8);
				if (IsReference(type))
					RefSummary(p, type, depth, outText, outKind, outAddr, outDyn);
				else if (type.StartsWith("function "))
				{
					String fname = scope .();
					FunctionName(p, fname);
					outText.Append(fname);
				}
				else if (type.EndsWith("*"))
					outText.AppendF("0x{:X}", p);
				else
					outText.Append("{...}");
			}
		}

		/// A reference: `null`, a String's text, a container's elements, a delegate's function, else
		/// the object's own type and address. outKind is set for a container (its children are made
		/// by the adapter), outDyn to the object's own type.
		void RefSummary(uint64 addr, StringView staticType, int depth, String outText, SynthKind* outKind = null, uint64* outAddr = null, String outDyn = null)
		{
			if (outAddr != null)
				*outAddr = addr;
			if (addr == 0)
			{
				outText.Append("null");
				return;
			}
			if (staticType.EndsWith("[]"))
			{
				outDyn?.Set(staticType);
				if (outKind != null)
					*outKind = .Array;
				ArraySummary(addr, staticType, depth, outText);
				return;
			}
			String dyn = scope .();
			ObjectType(addr, dyn);
			outDyn?.Set(dyn.IsEmpty ? staticType : dyn);
			if (staticType.StartsWith("delegate ") || dyn.Contains("$lambda_") || dyn == "Core.Delegate" || (dyn.IsEmpty && staticType.Contains("$lambda_")))
			{
				DelegateSummary(addr, outText);
				return;
			}
			if (dyn.IsEmpty)
			{
				outText.AppendF("{} (0x{:X})", staticType, addr);
				return;
			}
			if (dyn.StartsWith('('))
			{
				outText.Append(dyn);
				return;
			}
			if (dyn == "Core.String")
			{
				StringSummary(addr, outText);
				return;
			}
			if (dyn.StartsWith("Core.List<"))
			{
				if (outKind != null)
					*outKind = .List;
				ListSummary(addr, dyn, depth, outText);
				return;
			}
			if (dyn.StartsWith("Core.Dictionary<"))
			{
				if (outKind != null)
					*outKind = .Dictionary;
				DictionarySummary(addr, dyn, depth, outText);
				return;
			}
			outText.AppendF("{} (0x{:X})", dyn, addr);
		}

		/// `{ vtable, mPtr, mLength, mCapacity, mInline }`: the text (mPtr points at mInline for a short String).
		void StringSummary(uint64 addr, String outText)
		{
			List<uint8> h = scope .();
			if (!ReadMemory(addr, 24, h) || h.Count < 24)
			{
				outText.AppendF("Core.String (0x{:X})", addr);
				return;
			}
			TextAt(UN(h, 8, 8), (int64)UN(h, 16, 8), outText);
		}

		/// `{ vtable, target, fn }`: the function bound (`Zoo.Program.Twice`, `Lambda c2`).
		void DelegateSummary(uint64 addr, String outText)
		{
			List<uint8> h = scope .();
			if (!ReadMemory(addr, 24, h) || h.Count < 24)
			{
				outText.AppendF("delegate (0x{:X})", addr);
				return;
			}
			FunctionName(UN(h, 16, 8), outText);
		}

		/// Elements `start` .. `start + count` of the array object at `arr` (`{ vtable, length,
		/// elements }`, the elements at byte 16), each as a summary. False when the element size is
		/// not known here.
		bool ReadElements(uint64 arr, StringView elemType, int64 start, int count, int depth, List<String> outItems,
			List<SynthKind> outKinds = null, List<uint64> outAddrs = null, List<String> outDyns = null)
		{
			let size = ValueSize(elemType);
			if (size <= 0)
				return false;
			if (count <= 0)
				return true;
			List<uint8> b = scope .();
			if (!ReadMemory(arr + 16 + (uint64)(start * size), count * size, b) || b.Count < count * size)
				return false;
			for (int i < count)
			{
				String s = new .();
				SynthKind kind = .None;
				uint64 addr = 0;
				String dyn = scope .();
				FormatBytes(elemType, b, i * size, depth, s, &kind, &addr, dyn);
				outItems.Add(s);
				outKinds?.Add(kind);
				outAddrs?.Add(addr);
				outDyns?.Add(new String(dyn));
			}
			return true;
		}

		/// `[a, b, c, ...] (n)` from the first elements.
		void ElementsText(uint64 arr, StringView elemType, int64 count, int depth, String outText)
		{
			if (depth >= 2 || count <= 0)
			{
				outText.Append((count <= 0) ? "[]" : "[...]");
				outText.AppendF(" ({})", count);
				return;
			}
			List<String> items = scope .();
			defer { ClearAndDeleteItems!(items); }
			let n = (int)Math.Min(count, cPreview);
			if (arr == 0 || !ReadElements(arr, elemType, 0, n, depth + 1, items))
			{
				outText.AppendF("[...] ({})", count);
				return;
			}
			outText.Append('[');
			for (let it in items)
			{
				if (@it.Index > 0)
					outText.Append(", ");
				outText.Append(it);
			}
			if (count > n)
				outText.Append(", ...");
			outText.AppendF("] ({})", count);
		}

		void ArraySummary(uint64 addr, StringView type, int depth, String outText)
		{
			List<uint8> h = scope .();
			if (!ReadMemory(addr, 16, h) || h.Count < 16)
			{
				outText.AppendF("{} (0x{:X})", type, addr);
				return;
			}
			ElementsText(addr, type.Substring(0, type.Length - 2), (int64)UN(h, 8, 8), depth, outText);
		}

		/// `{ vtable, mItems: T[], mCount }`.
		void ListSummary(uint64 addr, StringView type, int depth, String outText)
		{
			List<StringView> args = scope .();
			List<uint8> h = scope .();
			if (!GenericArgs(type, "Core.List", args) || args.Count != 1 || !ReadMemory(addr, 24, h) || h.Count < 24)
			{
				outText.AppendF("{} (0x{:X})", type, addr);
				return;
			}
			ElementsText(UN(h, 8, 8), args[0], (int64)UN(h, 16, 8), depth, outText);
		}

		/// The slots of a dictionary in use, in slot order: `{ vtable, mKeys, mValues, mStates (0
		/// empty, 1 in use, 2 removed), mCount, mUsed, mCapacity }`.
		bool DictionarySlots(uint64 addr, int limit, List<int> outSlots, out uint64 keys, out uint64 values, out int64 count)
		{
			keys = 0;
			values = 0;
			count = 0;
			List<uint8> h = scope .();
			if (!ReadMemory(addr, 56, h) || h.Count < 56)
				return false;
			keys = UN(h, 8, 8);
			values = UN(h, 16, 8);
			let states = UN(h, 24, 8);
			count = (int64)UN(h, 32, 8);
			let cap = (int64)UN(h, 48, 8);
			if (states == 0 || cap <= 0)
				return true;
			List<uint8> st = scope .();
			let n = (int)Math.Min(cap, 65536);
			if (!ReadMemory(states + 16, n, st))
				return false;
			for (int i < st.Count)
				if (st[i] == 1)
				{
					outSlots.Add(i);
					if (outSlots.Count >= limit)
						break;
				}
			return true;
		}

		/// `{k: v, ...} (n)`.
		void DictionarySummary(uint64 addr, StringView type, int depth, String outText)
		{
			List<StringView> args = scope .();
			List<int> slots = scope .();
			uint64 keys = 0, values = 0;
			int64 count = 0;
			if (!GenericArgs(type, "Core.Dictionary", args) || args.Count != 2 || !DictionarySlots(addr, cPreview, slots, out keys, out values, out count))
			{
				outText.AppendF("{} (0x{:X})", type, addr);
				return;
			}
			if (depth >= 2 || count <= 0)
			{
				outText.AppendF("{} ({})", (count <= 0) ? "{}" : "{...}", count);
				return;
			}
			outText.Append('{');
			for (let s in slots)
			{
				List<String> k = scope .();
				List<String> v = scope .();
				defer { ClearAndDeleteItems!(k); ClearAndDeleteItems!(v); }
				if (@s.Index > 0)
					outText.Append(", ");
				if (!ReadElements(keys, args[0], s, 1, depth + 1, k) || !ReadElements(values, args[1], s, 1, depth + 1, v))
				{
					outText.Append("...");
					break;
				}
				outText.AppendF("{}: {}", k[0], v[0]);
			}
			if (count > slots.Count)
				outText.Append(", ...");
			outText.AppendF("}} ({})", count);
		}

		// ------------------------------------------------------------------ variables

		/// A variable path lldb can read (`counts`, `cell.Value`), not one rooted at a pin
		/// (`a3.object`: lldb reads `a3` as the variable).
		static bool IsPathRoot(StringView path)
		{
			if (path.IsEmpty)
				return false;
			int i = 0;
			while (i < path.Length && path[i].IsLower)
				i++;
			if (i == 0 || i == path.Length || !path[i].IsDigit)
				return true;
			while (i < path.Length && path[i].IsDigit)
				i++;
			return i == path.Length || path[i] != '.';
		}

		/// The value text of a variable lldb gave (dv.Type already in Treadle's spelling): see the
		/// type's summary at the top of this file. `path` is lldb's evaluateName ("" for none).
		void Present(DebugVariable dv, bool isRef, StringView path, int depth)
		{
			if (isRef)
			{
				var text = StringView(dv.Value);
				let sp = text.IndexOf(' ');
				if (sp > 0)
					text = text.Substring(0, sp);
				if (!text.StartsWith("0x"))
					return;
				let addr = uint64.Parse(text.Substring(2), .HexNumber).GetValueOrDefault();
				if (addr == 0)
				{
					dv.Value.Set("null");
					dv.ChildrenRef = 0;
					return;
				}
				SynthKind kind = .None;
				String dyn = scope .();
				String sum = scope .();
				RefSummary(addr, dv.Type, depth, sum, &kind, null, dyn);
				if (sum.IsEmpty)
					return;
				dv.Value.Set(sum);
				if (kind != .None)
					dv.ChildrenRef = NewSynth(kind, addr, dyn, IsPathRoot(path) ? path : "");
				return;
			}
			if (dv.ChildrenRef == 0 || depth >= 2)
				return;
			let vr = Request("variables", scope $"{{\"variablesReference\":{dv.ChildrenRef}}}");
			defer delete vr;
			let list = vr?.Get("body")?.Get("variables");
			if (list == null || !list.IsArray || list.Items.IsEmpty)
				return;
			let items = list.Items;
			String s = scope .();
			if (dv.Type == "StringView" || dv.Type == "Core.StringView")
			{
				// { Ptr, Length }: the text
				uint64 ptr = 0;
				int64 len = 0;
				for (let c in items)
				{
					var v = Str(c, "value");
					let sp = v.IndexOf(' ');
					if (sp > 0)
						v = v.Substring(0, sp);
					if (Str(c, "name") == "Ptr" && v.StartsWith("0x"))
						ptr = uint64.Parse(v.Substring(2), .HexNumber).GetValueOrDefault();
					else if (Str(c, "name") == "Length")
						len = int64.Parse(v).GetValueOrDefault();
				}
				TextAt(ptr, len, s);
			}
			else if (items.Count == 2 && Str(items[0], "name") == "tag" && Str(items[1], "name") == "payload")
			{
				// a payload enum: Case(payload...)
				let tag = Str(items[0], "value");
				s.Append(tag);
				let pr = Int(items[1], "variablesReference");
				if (pr != 0)
				{
					let pv = Request("variables", scope $"{{\"variablesReference\":{pr}}}");
					defer delete pv;
					let cases = pv?.Get("body")?.Get("variables");
					if (cases != null && cases.IsArray)
						for (let c in cases.Items)
						{
							if (Str(c, "name") != tag)
								continue;
							DebugVariable cv = scope .();
							MapVariable(c, null, cv, depth + 1);
							if (cv.Type.StartsWith(dv.Type) && cv.Type.Length > dv.Type.Length && cv.Type[dv.Type.Length] == '.' && cv.ChildrenRef != 0)
							{
								// several values: the case's structure of item0, item1, ...
								AppendMembers(cv.ChildrenRef, depth + 1, false, s);
							}
							else
								s.AppendF("({})", cv.Value);
						}
				}
			}
			else if (items.Count == 2 && Str(items[0], "name") == "hasValue" && Str(items[1], "name") == "value")
			{
				// a nullable: null or the value
				if (Str(items[0], "value") != "true")
					s.Append("null");
				else
				{
					DebugVariable cv = scope .();
					MapVariable(items[1], null, cv, depth + 1);
					s.Append(cv.Value);
				}
			}
			else if (dv.Type.StartsWith('('))
				AppendMembers(dv.ChildrenRef, depth, false, s);
			else
				AppendMembers(dv.ChildrenRef, depth, true, s);
			if (!s.IsEmpty)
				dv.Value.Set(s);
		}

		/// `(a, b)` (named: `{X = 3, Y = 4}`) of a structure's first members, each summarised.
		void AppendMembers(int64 reference, int depth, bool named, String outText)
		{
			let vr = Request("variables", scope $"{{\"variablesReference\":{reference}}}");
			defer delete vr;
			let list = vr?.Get("body")?.Get("variables");
			if (list == null || !list.IsArray)
				return;
			outText.Append(named ? "{" : "(");
			for (let c in list.Items)
			{
				if (@c.Index == 6)
				{
					outText.Append(", ...");
					break;
				}
				if (@c.Index > 0)
					outText.Append(", ");
				DebugVariable cv = scope .();
				MapVariable(c, null, cv, depth + 1);
				if (named)
					outText.AppendF("{} = {}", Str(c, "name"), cv.Value);
				else
					outText.Append(cv.Value);
			}
			outText.Append(named ? "}" : ")");
		}

		/// The children of a container the adapter made (DoChildren).
		void SynthChildren(SynthNode n, List<DebugVariable> outVars)
		{
			mCurFrameId = n.FrameId;
			uint64 arr = 0;
			int64 count = 0;
			StringView elemType = "";
			StringView pathSuffix = "";
			List<StringView> args = scope .();
			switch (n.Kind)
			{
			case .Array:
				List<uint8> h = scope .();
				if (!ReadMemory(n.Addr, 16, h) || h.Count < 16)
					return;
				arr = n.Addr;
				count = (int64)UN(h, 8, 8);
				elemType = StringView(n.Type, 0, n.Type.Length - 2);
				pathSuffix = "->elements";
			case .List:
				List<uint8> h = scope .();
				if (!GenericArgs(n.Type, "Core.List", args) || args.Count != 1 || !ReadMemory(n.Addr, 24, h) || h.Count < 24)
					return;
				arr = UN(h, 8, 8);
				count = (int64)UN(h, 16, 8);
				elemType = args[0];
				pathSuffix = "->mItems->elements";
			case .Dictionary:
				DictionaryChildren(n, outVars);
				return;
			case .None:
				return;
			}
			let shown = (int)Math.Min(count, cMaxChildren);
			if (arr == 0 || shown <= 0)
				return;
			List<String> items = scope .();
			List<SynthKind> kinds = scope .();
			List<uint64> addrs = scope .();
			List<String> dyns = scope .();
			defer { ClearAndDeleteItems!(items); ClearAndDeleteItems!(dyns); }
			if (ReadElements(arr, elemType, 0, shown, 1, items, kinds, addrs, dyns))
			{
				for (int i < shown)
				{
					DebugVariable dv = new .();
					dv.Name.AppendF("[{}]", i);
					dv.Label.Set(dv.Name);
					dv.Type.Set(elemType);
					dv.Value.Set(items[i]);
					String path = scope .();
					if (!n.Path.IsEmpty)
						path.AppendF("{}{}[{}]", n.Path, pathSuffix, i);
					dv.ChildrenRef = ElementChildren(kinds[i], addrs[i], dyns[i], path);
					outVars.Add(dv);
				}
			}
			else if (!n.Path.IsEmpty)
			{
				// elements of a value type the adapter does not lay out: through lldb
				for (int i < shown)
				{
					DebugVariable dv = new .();
					String path = scope $"{n.Path}{pathSuffix}[{i}]";
					EvaluatePath(path, dv);
					dv.Name.Clear();
					dv.Name.AppendF("[{}]", i);
					dv.Label.Set(dv.Name);
					outVars.Add(dv);
				}
			}
			else
			{
				DebugVariable dv = new .();
				dv.Name.Set("elements");
				dv.Label.Set("elements");
				dv.Value.AppendF("{} of {} (shown for a named variable only)", count, elemType);
				outVars.Add(dv);
			}
		}

		void DictionaryChildren(SynthNode n, List<DebugVariable> outVars)
		{
			List<StringView> args = scope .();
			List<int> slots = scope .();
			uint64 keys = 0, values = 0;
			if (!GenericArgs(n.Type, "Core.Dictionary", args) || args.Count != 2 || !DictionarySlots(n.Addr, cMaxChildren, slots, out keys, out values, ?))
				return;
			for (let s in slots)
			{
				List<String> k = scope .();
				List<String> v = scope .();
				List<SynthKind> kinds = scope .();
				List<uint64> addrs = scope .();
				List<String> dyns = scope .();
				defer { ClearAndDeleteItems!(k); ClearAndDeleteItems!(v); ClearAndDeleteItems!(dyns); }
				DebugVariable dv = new .();
				if (!ReadElements(keys, args[0], s, 1, 1, k))
					k.Add(new String()..AppendF("slot {}", s));
				dv.Name.AppendF("[{}]", k[0]);
				dv.Label.Set(dv.Name);
				dv.Type.Set(args[1]);
				String path = scope .();
				if (!n.Path.IsEmpty)
					path.AppendF("{}->mValues->elements[{}]", n.Path, s);
				if (ReadElements(values, args[1], s, 1, 1, v, kinds, addrs, dyns))
				{
					dv.Value.Set(v[0]);
					dv.ChildrenRef = ElementChildren(kinds[0], addrs[0], dyns[0], path);
				}
				else if (!path.IsEmpty)
				{
					String name = scope .(dv.Name);
					EvaluatePath(path, dv);
					dv.Name.Set(name);
					dv.Label.Set(name);
				}
				else
					dv.Value.Set("{...}");
				outVars.Add(dv);
			}
		}

		/// What an element expands to: a container's elements, an object's fields (through lldb,
		/// when there is a path to it), nothing for the rest.
		int64 ElementChildren(SynthKind kind, uint64 addr, StringView dyn, StringView path)
		{
			if (addr == 0)
				return 0;
			if (kind != .None)
				return NewSynth(kind, addr, dyn, path);
			if (path.IsEmpty || dyn == "Core.String" || dyn.StartsWith('(') || dyn.IsEmpty)
				return 0;
			DebugVariable tmp = scope .();
			EvaluatePath(path, tmp);
			return tmp.ChildrenRef;
		}

		/// lldb's value at a variable path (evaluate, the path read without the expression parser).
		void EvaluatePath(StringView path, DebugVariable dv)
		{
			String a = scope .();
			a.Append("{\"expression\":");
			UpdateJson.WriteString(path, a);
			a.AppendF(",\"frameId\":{},\"context\":\"hover\"}}", mCurFrameId);
			let r = Request("evaluate", a);
			defer delete r;
			dv.Name.Set(path);
			dv.Label.Set(path);
			if (r == null || !r.GetBool("success", false))
			{
				dv.Value.Set("<unreadable>");
				return;
			}
			let body = r.Get("body");
			body.GetString("result", dv.Value);
			String ctype = scope .();
			body.GetString("type", ctype);
			bool isRef;
			using (mLock.Enter())
				MapType(ctype, dv.Type, out isRef);
			dv.ChildrenRef = Int(body, "variablesReference");
			if (dv.ChildrenRef != 0)
				mRefFrame[dv.ChildrenRef] = mCurFrameId;
			Present(dv, isRef, path, 1);
		}
	}
}
