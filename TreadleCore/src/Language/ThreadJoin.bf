using System;
using System.Diagnostics;
using System.Threading;

namespace Treadle.Language
{
	/// Joins a thread once, with a timeout that works on every platform.
	///
	/// Beef's POSIX `Thread.Join(ms)` hands a relative time to `pthread_timedjoin_np`, which takes an
	/// absolute one: a timed Join returns false at once unless the thread already ended. And a thread
	/// that a timed Join (or `IsAlive`) did join must never be joined again: a second `pthread_join`
	/// is undefined (the editor crashed in `BfpThread_WaitFor` on Linux). So the caller keeps a
	/// `joined` flag per thread and every join goes through here: on Linux it polls `Join(0)` (which
	/// joins a thread that has ended and returns at once otherwise) until the timeout.
	static class ThreadJoin
	{
		/// True when `thread` has ended (and is now joined); false when `timeoutMs` (-1: no limit)
		/// passed first. A null thread, or one already joined, is done.
		public static bool Join(Thread thread, ref bool joined, int timeoutMs = -1)
		{
			if (thread == null || joined)
				return true;
#if BF_PLATFORM_WINDOWS
			if (!thread.Join(timeoutMs))
				return false;
			joined = true;
			return true;
#else
			let watch = scope Stopwatch(true);
			while (true)
			{
				if (thread.Join(0))
				{
					joined = true;
					return true;
				}
				if (timeoutMs >= 0 && watch.ElapsedMilliseconds >= timeoutMs)
					return false;
				Thread.Sleep(1);
			}
#endif
		}
	}
}
