using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Treadle.Language;
using Treadle.Update;

namespace Treadle.Debug.Dap
{
	/// One Debug Adapter Protocol server (lldb-dap) as a child process: requests are written to its
	/// stdin as `Content-Length` framed JSON, responses and events are read from its stdout on a
	/// thread and queued in arrival order. The server and the program it launches live in a job
	/// object, so they end with the editor and Kill ends both.
	class DapConnection
	{
		class Shared
		{
			public Monitor Lock = new .() ~ delete _;
			public List<UpdateJson> Inbox = new .() ~ DeleteContainerAndItems!(_);
			public bool Closed;
			public int Owners = 2;
		}

		SpawnedProcess mProcess ~ delete _;
		ProcessJob mJob ~ delete _;
		UnbufferedFileStream mIn ~ delete _;
		Thread mReader;
		bool mReaderJoined;
		Shared mShared;
		int32 mSeq;
		public String Error = new .() ~ delete _;
		/// Every message both ways, for the self test and for diagnosing (TREADLE_DEBUG_TRACE=1).
		public bool Trace;
		public List<String> TraceLines = new .() ~ DeleteContainerAndItems!(_);
		Monitor mTraceLock = new .() ~ delete _;

		public ~this()
		{
			Kill();
			if (mReader != null && ThreadJoin.Join(mReader, ref mReaderJoined, 3000))
				delete mReader;
			Release();
		}

		void Release()
		{
			if (mShared == null)
				return;
			bool free;
			using (mShared.Lock.Enter())
				free = --mShared.Owners == 0;
			if (free)
				delete mShared;
			mShared = null;
		}

		public bool Start(StringView exe, List<String> args, String outError)
		{
			String argText = scope .();
			for (let a in args)
			{
				if (!argText.IsEmpty)
					argText.Append(' ');
				argText.Append(a);
			}
			ProcessStartInfo psi = scope .();
			// Windows: the job (below); Linux: a process group of its own that Kill ends, and SIGKILL
			// when the thread that starts it ends (a killed editor); the program it debugs dies with it
			mJob = new .();
			mJob.PrepareStart(psi, exe, argText, true, true);
			psi.UseShellExecute = false;
			psi.RedirectStandardInput = true;
			psi.RedirectStandardOutput = true;
			psi.RedirectStandardError = false;
			psi.CreateNoWindow = true;
			mProcess = new .();
			if (mProcess.Start(psi) case .Err)
			{
				outError.AppendF("could not start {}", exe);
				return false;
			}
			mJob.Assign(mProcess);
			mIn = new .();
			if (mProcess.AttachStandardInput(mIn) case .Err)
			{
				outError.Append("could not open the debugger's input");
				Kill();
				return false;
			}
			UnbufferedFileStream outStream = new .();
			if (mProcess.AttachStandardOutput(outStream) case .Err)
			{
				delete outStream;
				outError.Append("could not open the debugger's output");
				Kill();
				return false;
			}
			mShared = new .();
			let shared = mShared;
			mReader = new Thread(new () => ReadLoop(outStream, shared, this));
			mReader.SetName("Treadle debugger messages");
			mReader.IsBackground = true;
			mReader.Start(false);
			return true;
		}

		public bool IsAlive => mProcess != null && !mProcess.HasExited;
		public int ProcessId => (mProcess != null) ? mProcess.ProcessId : 0;

		public bool Closed
		{
			get
			{
				if (mShared == null)
					return true;
				using (mShared.Lock.Enter())
					return mShared.Closed;
			}
		}

		/// Sends a request; `argsJson` is the arguments object's text ("" = none). Returns its seq.
		public int32 Send(StringView command, StringView argsJson)
		{
			let seq = ++mSeq;
			String body = scope .();
			body.AppendF("{{\"seq\":{},\"type\":\"request\",\"command\":", seq);
			UpdateJson.WriteString(command, body);
			if (!argsJson.IsEmpty)
				body.AppendF(",\"arguments\":{}", argsJson);
			body.Append('}');
			String frame = scope .();
			frame.AppendF("Content-Length: {}\r\n\r\n", body.Length);
			frame.Append(body);
			if (Trace)
				AddTrace(scope $"> {body}");
			if (mIn != null)
			{
				Span<uint8> data = .((uint8*)frame.Ptr, frame.Length);
				while (data.Length > 0)
				{
					switch (mIn.TryWrite(data))
					{
					case .Ok(let n):
						if (n <= 0)
							return seq;
						data = data.Slice(n);
					case .Err:
						return seq;
					}
				}
			}
			return seq;
		}

		void AddTrace(StringView line)
		{
			using (mTraceLock.Enter())
			{
				if (TraceLines.Count < 20000)
					TraceLines.Add(new String(line));
			}
		}

		/// The next message read (a response or an event; the caller owns it), or null.
		public UpdateJson Take()
		{
			if (mShared == null)
				return null;
			using (mShared.Lock.Enter())
			{
				if (mShared.Inbox.IsEmpty)
					return null;
				let m = mShared.Inbox[0];
				mShared.Inbox.RemoveAt(0);
				return m;
			}
		}

		public void Kill()
		{
			if (mProcess == null || mProcess.HasExited)
				return;
			if (mJob != null)
				mJob.Kill(mProcess);
			else
				mProcess.Kill(1, .KillChildren);
		}

		/// Waits for the server to end by itself (after `disconnect`).
		public bool WaitExit(int ms)
		{
			if (mProcess == null)
				return true;
			return mProcess.WaitFor(ms);
		}

		static void ReadLoop(UnbufferedFileStream stream, Shared shared, DapConnection owner)
		{
			List<uint8> buf = scope .();
			uint8[4096] chunk = ?;
			bool done = false;
			while (!done)
			{
				// Complete frames in the buffer first.
				while (true)
				{
					int hdrEnd = -1;
					for (int i = 0; i + 3 < buf.Count; i++)
						if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n')
						{
							hdrEnd = i;
							break;
						}
					if (hdrEnd < 0)
						break;
					StringView header = .((char8*)buf.Ptr, hdrEnd);
					int len = -1;
					for (var line in header.Split('\n'))
					{
						line.Trim();
						if (line.StartsWith("Content-Length:", .OrdinalIgnoreCase))
						{
							var num = line.Substring(15);
							num.Trim();
							if (int.Parse(num) case .Ok(let v)) len = v;
						}
					}
					if (len < 0)
					{
						// Not a frame header (stray text): drop it.
						buf.RemoveRange(0, hdrEnd + 4);
						continue;
					}
					if (buf.Count < hdrEnd + 4 + len)
						break;
					StringView body = .((char8*)buf.Ptr + hdrEnd + 4, len);
					if (owner.Trace)
						owner.AddTrace(scope $"< {body}");
					if (UpdateJson.Parse(body) case .Ok(let msg))
					{
						using (shared.Lock.Enter())
							shared.Inbox.Add(msg);
					}
					buf.RemoveRange(0, hdrEnd + 4 + len);
				}
				switch (stream.TryRead(.(&chunk, chunk.Count)))
				{
				case .Ok(let n):
					if (n <= 0)
						done = true;
					else
						buf.AddRange(Span<uint8>(&chunk, n));
				case .Err:
					done = true;
				}
			}
			delete stream;
			bool free;
			using (shared.Lock.Enter())
			{
				shared.Closed = true;
				free = --shared.Owners == 0;
			}
			if (free)
				delete shared;
		}
	}
}
