using System;
using System.Collections;
using Treadle.Update;

namespace Treadle.Debug.Dap
{
	/// What the Memory and Disassembly panels ask the debugger while the program is stopped
	/// (docs/Debugging.md, "Under the hood"). One request, answered once; the UI thread queues it with
	/// `LldbDapAdapter.Inspect` and takes the answer back with `TakeInspect`.
	class InspectRequest
	{
		public enum Kind
		{
			/// `Count` bytes at `Address` (DAP readMemory).
			Memory,
			/// The address of the variable `Expression` (its debug name: `pet`, `a2.object`, `this`) in
			/// frame `Frame`: Result (the variables' memoryReference), then `Count` bytes there.
			Variable,
			/// The frame's stack pointer, frame pointer and instruction pointer (Result, Result2, Result3),
			/// and the instruction pointer as a file address of the module (FileAddress, Text: the module).
			Frame
		}

		public Kind What;
		public int32 Id;
		public int Frame;
		public String Expression = new .() ~ delete _;
		public uint64 Address;
		public int Count;
		/// Variable: the bytes are where its value points (a class reference whose type lldb does not show as a pointer).
		public bool Follow;
		// ---- the answer
		public bool Done;
		public bool Failed;
		public String Error = new .() ~ delete _;
		public List<uint8> Bytes = new .() ~ delete _;
		public uint64 Result;
		public uint64 Result2;
		public uint64 Result3;
		public uint64 FileAddress;
		/// Variable: the bytes are where the variable points (Address), not the variable itself (Result).
		public bool Followed;
		public String Text = new .() ~ delete _;
	}

	extension LldbDapAdapter
	{
		List<InspectRequest> mInspectQueue = new .() ~ DeleteContainerAndItems!(_);
		List<InspectRequest> mInspectDone = new .() ~ DeleteContainerAndItems!(_);
		int32 mInspectNext = 1;

		/// Queues `r` (the adapter owns it until TakeInspect) and returns its id. Answered only while
		/// the program is stopped; a request made while running fails.
		public int32 Inspect(InspectRequest r)
		{
			using (mLock.Enter())
			{
				r.Id = mInspectNext++;
				mInspectQueue.Add(r);
				// a worker that is not running never answers: fail it now
				if (!mWorkerRunning)
				{
					mInspectQueue.Remove(r);
					r.Failed = true;
					r.Done = true;
					r.Error.Set("The program is not being debugged.");
					mInspectDone.Add(r);
				}
			}
			return r.Id;
		}

		/// The answer to request `id` (the caller owns it), or null while it is pending.
		public InspectRequest TakeInspect(int32 id)
		{
			using (mLock.Enter())
			{
				for (let r in mInspectDone)
					if (r.Id == id)
					{
						mInspectDone.Remove(r);
						return r;
					}
			}
			return null;
		}

		/// Worker thread: answers the queued requests. True when one was answered.
		bool ServiceInspect()
		{
			InspectRequest r = null;
			using (mLock.Enter())
			{
				if (!mInspectQueue.IsEmpty)
				{
					r = mInspectQueue[0];
					mInspectQueue.RemoveAt(0);
				}
			}
			if (r == null)
				return false;
			switch (r.What)
			{
			case .Memory:
				InspectMemory(r, r.Address, r.Count);
			case .Variable:
				if (r.Frame < 0 || r.Frame >= mFrameIds.Count)
					Fail(r, "That frame is gone: the program has moved on.");
				else
					InspectVariable(r, mFrameIds[r.Frame]);
			case .Frame:
				if (r.Frame < 0 || r.Frame >= mFrameIds.Count)
					Fail(r, "That frame is gone: the program has moved on.");
				else
					InspectFrame(r, mFrameIds[r.Frame]);
			}
			r.Done = true;
			using (mLock.Enter())
				mInspectDone.Add(r);
			return true;
		}

		/// A variable's bytes. lldb-dap's memoryReference of a pointer (a class reference, `this` of a struct
		/// function) is the address it holds, so those are read where they point (Followed); any other
		/// variable is read where it is stored, and with Follow its first 8 bytes are taken as the address.
		void InspectVariable(InspectRequest r, int64 frameId)
		{
			String value = scope .();
			if (!VariableAddress(frameId, r.Expression, out r.Result, r.Text, value))
			{
				if (r.Text.EndsWith('*') && ParseAddress(value, var v) && v == 0)
					Fail(r, scope $"{r.Expression} is null: it references nothing.");
				else
					Fail(r, scope $"The debugger has no address for {r.Expression}: it is held in a register or was optimised away.");
				return;
			}
			var ctype = StringView(r.Text);
			ctype.Trim();
			if (ctype.EndsWith('*'))
			{
				r.Followed = true;
				InspectMemory(r, r.Result, r.Count);
				return;
			}
			if (r.Follow)
			{
				InspectMemory(r, r.Result, 8);
				if (r.Failed)
					return;
				uint64 target = 0;
				for (int i < Math.Min(8, r.Bytes.Count))
					target |= (uint64)r.Bytes[i] << (8 * i);
				r.Bytes.Clear();
				r.Followed = true;
				if (target == 0)
				{
					Fail(r, scope $"{r.Expression} is null: it references nothing.");
					return;
				}
				InspectMemory(r, target, r.Count);
				return;
			}
			InspectMemory(r, r.Result, r.Count);
		}

		static void Fail(InspectRequest r, StringView why)
		{
			r.Failed = true;
			r.Error.Set(why);
		}

		void InspectMemory(InspectRequest r, uint64 addr, int count)
		{
			r.Address = addr;
			if (addr == 0)
			{
				Fail(r, "The address is 0 (null): nothing to read.");
				return;
			}
			let n = Math.Clamp(count, 1, 65536);
			let resp = Request("readMemory", scope $"{{\"memoryReference\":\"0x{addr:X}\",\"offset\":0,\"count\":{n}}}");
			defer delete resp;
			String data = scope .();
			if (resp == null || !resp.GetBool("success", false) || !(resp.Get("body")?.GetString("data", data) ?? false) || data.IsEmpty)
			{
				String msg = scope .();
				resp?.GetString("message", msg);
				Fail(r, scope $"Memory at 0x{addr:X} cannot be read (not mapped by the program){(msg.IsEmpty ? "" : ": ")}{msg}.");
				return;
			}
			Base64Decode(data, r.Bytes);
			if (r.Bytes.IsEmpty)
				Fail(r, scope $"Memory at 0x{addr:X} cannot be read (not mapped by the program).");
		}

		/// The address of a variable of a frame, by its debug name: the `memoryReference` lldb-dap gives
		/// with each variable (the address of its storage).
		bool VariableAddress(int64 frameId, StringView name, out uint64 addr, String outType, String outValue)
		{
			addr = 0;
			let sr = Request("scopes", scope $"{{\"frameId\":{frameId}}}");
			defer delete sr;
			let scopes = sr?.Get("body")?.Get("scopes");
			if (scopes == null || !scopes.IsArray)
				return false;
			for (let s in scopes.Items)
			{
				let vr = Request("variables", scope $"{{\"variablesReference\":{Int(s, "variablesReference")}}}");
				defer delete vr;
				let list = vr?.Get("body")?.Get("variables");
				if (list == null || !list.IsArray)
					continue;
				for (let v in list.Items)
				{
					var vn = Str(v, "name");
					let at = vn.IndexOf(" @ ");
					if (at > 0)
						vn = vn.Substring(0, at);
					if (vn != name)
						continue;
					String mem = scope .();
					v.GetString("type", outType);
					v.GetString("value", outValue);
					if (v.GetString("memoryReference", mem) && ParseAddress(mem, out addr) && addr != 0)
						return true;
					// a pointer without one: the address it holds is its value
					var ct = StringView(outType);
					ct.Trim();
					if (ct.EndsWith('*'))
						return ParseAddress(outValue, out addr) && addr != 0;
					// older servers: the address through an expression
					let er = Request("evaluate", scope $"{{\"expression\":\"&{name}\",\"frameId\":{frameId},\"context\":\"watch\"}}");
					defer delete er;
					String val = scope .();
					if (er != null && er.GetBool("success", false) && (er.Get("body")?.GetString("result", val) ?? false) && ParseAddress(val, out addr) && addr != 0)
						return true;
					return false;
				}
			}
			return false;
		}

		void InspectFrame(InspectRequest r, int64 frameId)
		{
			uint64 Reg(StringView name)
			{
				let er = Request("evaluate", scope $"{{\"expression\":\"${name}\",\"frameId\":{frameId},\"context\":\"watch\"}}");
				defer delete er;
				String val = scope .();
				if (er != null && er.GetBool("success", false) && (er.Get("body")?.GetString("result", val) ?? false) && ParseAddress(val, var a))
					return a;
				return 0;
			}
			r.Result = Reg("rsp");
			r.Result2 = Reg("rbp");
			r.Result3 = Reg("pc");
			if (r.Result3 == 0)
				r.Result3 = Reg("rip");
			if (r.Result3 == 0)
			{
				Fail(r, "The debugger did not give the frame's registers.");
				return;
			}
			// `image lookup -a`: "Address: M1.exe[0x0000000140001d24] (M1.exe..text + 3364)"
			let lr = Request("evaluate", scope $"{{\"expression\":\"`image lookup -a 0x{r.Result3:X}\",\"frameId\":{frameId},\"context\":\"repl\"}}");
			defer delete lr;
			String text = scope .();
			lr?.Get("body")?.GetString("result", text);
			let at = text.IndexOf("Address: ");
			if (at >= 0)
			{
				let open = text.IndexOf('[', at);
				let close = (open > 0) ? text.IndexOf(']', open) : -1;
				if (open > 0 && close > open)
				{
					r.Text.Set(text.Substring(at + 9, open - at - 9));
					ParseAddress(text.Substring(open + 1, close - open - 1), out r.FileAddress);
				}
			}
		}

		/// `0x1A2B`, `1A2B` after `0x`, or a decimal number; text after the number is ignored.
		public static bool ParseAddress(StringView text, out uint64 value)
		{
			value = 0;
			var t = text;
			t.Trim();
			let sp = t.IndexOf(' ');
			if (sp > 0)
				t = t.Substring(0, sp);
			bool hex = t.StartsWith("0x") || t.StartsWith("0X");
			if (hex)
				t = t.Substring(2);
			if (t.IsEmpty)
				return false;
			for (let c in t.RawChars)
			{
				int d;
				if (c >= '0' && c <= '9') d = c - '0';
				else if (hex && c >= 'a' && c <= 'f') d = c - 'a' + 10;
				else if (hex && c >= 'A' && c <= 'F') d = c - 'A' + 10;
				else return false;
				value = value * (hex ? 16 : 10) + (uint64)d;
			}
			return true;
		}
	}
}
