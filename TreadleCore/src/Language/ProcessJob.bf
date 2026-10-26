using System;
using System.Diagnostics;
using System.Threading;

namespace Treadle.Language
{
	/// Ties a child process (and everything it starts) to the editor.
	///
	/// Windows: a job object that holds the child, with "kill when the last handle closes" set. The
	/// editor owns the only handle, so the children (the compiler, clang and lld, a program started by
	/// Run, lldb-dap and the program it debugs) end with the editor even when it crashes or is killed,
	/// and Kill() ends the whole tree at once (Cancel Build, Stop).
	///
	/// Linux: there are no job objects. A child started through PrepareStart with `ownGroup` runs in a
	/// process group of its own (`setsid`, which execs in place, so the process id stays the one Beef
	/// started); Kill() and deleting the job (a handle that was not released) send SIGKILL to that whole
	/// group. A killed editor cannot do that, so `parentDeath` adds `setpriv --pdeathsig KILL` (the child
	/// gets SIGKILL when the editor thread that started it ends), and a Treadle program started by the
	/// editor asks for the same itself (the runtime's `prctl(PR_SET_PDEATHSIG)` when its parent is the
	/// process named by TREADLE_RUN_PARENT, docs/Debugging.md). A child started without a group is
	/// ended with its descendants one by one (Beef's tree kill).
	///
	/// If Windows refuses a job (an older system, or an outer job that forbids nesting) the child
	/// runs without one: Take() then returns the reason once, for the Output Log, and every call
	/// still works (Kill falls back to the process tree kill).
	class ProcessJob
	{
#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* CreateJobObjectW(void* attributes, char16* name);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 SetInformationJobObject(void* job, int32 infoClass, void* info, uint32 length);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 AssignProcessToJobObject(void* job, void* process);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 TerminateJobObject(void* job, uint32 exitCode);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* OpenProcess(uint32 access, int32 inherit, uint32 pid);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 CloseHandle(void* h);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern uint32 GetLastError();
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 GetExitCodeProcess(void* process, uint32* code);

		const int32 JobObjectExtendedLimitInformation = 9;
		const uint32 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
		const uint32 PROCESS_TERMINATE = 0x0001;
		const uint32 PROCESS_SET_QUOTA = 0x0100;
		const uint32 PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
		const uint32 STILL_ACTIVE = 259;
		const int cInfoSize = 144; // JOBOBJECT_EXTENDED_LIMIT_INFORMATION on a 64-bit system
		const int cFlagsAt = 16; // its LimitFlags

		void* mJob;
#else
		[CLink] static extern int32 kill(int32 pid, int32 sig);
		[CLink] static extern void* fopen(char8* path, char8* mode);
		[CLink] static extern char8* fgets(char8* buf, int32 size, void* file);
		[CLink] static extern int32 fclose(void* file);
		[CLink] static extern int32 getpid();
		const int32 SIGKILL = 9;
		const String cSetsid = "/usr/bin/setsid";
		const String cSetpriv = "/usr/bin/setpriv";

		/// The group's id (the child's process id) once Assign took a child PrepareStart put in a group.
		int32 mGroup;
		bool mReleased;
		/// PrepareStart wrapped the start in `setsid`: Assign takes the child's group.
		public bool Grouped;
#endif
		bool mAssigned;

		/// 0: no refusal yet; else the Windows error of the first refused job (+1, so 0 stays free).
		static int32 sRefused;
		static int32 sRefusedTaken;
		static int32 sParentSet;

		/// The reason the first job was refused, once ("" when none or already taken). The
		/// editor puts it in the Output Log.
		public static void Take(String outText)
		{
			if (sRefused == 0 || Interlocked.CompareExchange(ref sRefusedTaken, 1, 0) != 0)
				return;
			outText.AppendF("Windows did not accept a job for the build and checker processes (error {}): they are not tied to the editor and may keep running if it is killed. Cancel Build still works.", sRefused - 1);
		}

		static void Refused(uint32 error)
		{
			Interlocked.CompareExchange(ref sRefused, (int32)error + 1, 0);
		}

		public this()
		{
#if BF_PLATFORM_WINDOWS
			mJob = CreateJobObjectW(null, null);
			if (mJob == null)
			{
				Refused(GetLastError());
				return;
			}
			uint8[cInfoSize] info = default;
			*(uint32*)&info[cFlagsAt] = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
			if (SetInformationJobObject(mJob, JobObjectExtendedLimitInformation, &info, cInfoSize) == 0)
			{
				Refused(GetLastError());
				CloseHandle(mJob);
				mJob = null;
			}
#endif
		}

		public ~this()
		{
#if BF_PLATFORM_WINDOWS
			// The last handle: whatever is still in the job ends with it.
			if (mJob != null)
				CloseHandle(mJob);
#else
			// The handle goes without a Release: the group ends, as a job would.
			if (mAssigned && !mReleased && mGroup > 0)
				KillGroup();
#endif
		}

		/// True once the process is in the job.
		public bool Assigned => mAssigned;

		/// Sets up `psi` to start `exe` with the argument text `argText` (quoted for the platform).
		/// Windows: the exe as is (Assign puts it in the job). Linux with `ownGroup`: through `setsid`
		/// (its own process group, Grouped is set), with `parentDeath` also through `setpriv --pdeathsig
		/// KILL` (it dies with the editor thread that starts it); either tool missing: the plain start.
		/// Also names this editor in TREADLE_RUN_PARENT (inherited) for the Treadle runtime.
		public void PrepareStart(ProcessStartInfo psi, StringView exe, StringView argText, bool ownGroup, bool parentDeath)
		{
			if (Interlocked.CompareExchange(ref sParentSet, 1, 0) == 0)
			{
#if !BF_PLATFORM_WINDOWS
				Environment.SetEnvironmentVariable("TREADLE_RUN_PARENT", scope $"{getpid()}").IgnoreError();
#endif
			}
#if !BF_PLATFORM_WINDOWS
			if (ownGroup && System.IO.File.Exists(cSetsid))
			{
				String args = scope .();
				if (parentDeath && System.IO.File.Exists(cSetpriv))
					args.AppendF("{} --pdeathsig KILL -- ", cSetpriv);
				if (exe.Contains(' '))
					args.AppendF("\"{}\"", exe);
				else
					args.Append(exe);
				if (!argText.IsEmpty)
					args.AppendF(" {}", argText);
				psi.SetFileName(cSetsid);
				psi.SetArguments(args);
				Grouped = true;
				return;
			}
#endif
			psi.SetFileName(exe);
			psi.SetArguments(argText);
		}

		/// True while the process with this id runs (self tests: the build tool is gone after Cancel,
		/// the program after its handle). Linux: a zombie (ended, not yet reaped) is not running.
		public static bool IsAlive(int processId)
		{
#if BF_PLATFORM_WINDOWS
			let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, (uint32)processId);
			if (h == null)
				return false;
			uint32 code = 0;
			let ok = GetExitCodeProcess(h, &code) != 0;
			CloseHandle(h);
			return ok && code == STILL_ACTIVE;
#else
			if (processId <= 0)
				return false;
			// /proc/<pid>/stat: "<pid> (<name>) <state> ..."; the name may hold spaces and ')'
			let f = fopen(scope $"/proc/{processId}/stat", "r");
			if (f == null)
				return false;
			char8[512] buf = default;
			let line = fgets(&buf[0], 512, f);
			fclose(f);
			if (line == null)
				return false;
			String text = scope .(&buf[0]);
			let close = text.LastIndexOf(')');
			if (close < 0 || close + 2 >= text.Length)
				return false;
			let state = text[close + 2];
			return state != 'Z' && state != 'X';
#endif
		}

		/// Puts a running process (and so everything it starts later) in the job. False when it
		/// could not (the first refusal of the session is reported by Take). Linux: takes the group
		/// PrepareStart made (false without one).
		public bool Assign(SpawnedProcess process)
		{
#if BF_PLATFORM_WINDOWS
			if (mJob == null)
				return false;
			let h = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, (uint32)process.ProcessId);
			if (h == null)
			{
				if (!process.HasExited)
					Refused(GetLastError());
				return false;
			}
			let ok = AssignProcessToJobObject(mJob, h) != 0;
			uint32 error = ok ? 0 : GetLastError();
			CloseHandle(h);
			if (!ok)
			{
				// A process that already ended cannot be assigned: nothing to report.
				if (!process.HasExited)
					Refused(error);
				return false;
			}
			mAssigned = true;
			return true;
#else
			if (!Grouped || process.ProcessId <= 0)
				return false;
			mGroup = (int32)process.ProcessId;
			mAssigned = true;
			return true;
#endif
		}

#if !BF_PLATFORM_WINDOWS
		/// SIGKILL to the group and to the leader itself (in case `setsid` has not run yet).
		void KillGroup()
		{
			kill(-mGroup, SIGKILL);
			kill(mGroup, SIGKILL);
		}
#endif

		/// Ends the process and everything it started. Without a job (or group), the process and the
		/// processes it started are ended one by one.
		public void Kill(SpawnedProcess process)
		{
#if BF_PLATFORM_WINDOWS
			if (mAssigned && mJob != null)
			{
				TerminateJobObject(mJob, 1);
				return;
			}
#else
			if (mAssigned && mGroup > 0)
			{
				KillGroup();
				return;
			}
#endif
			if (process != null && !process.HasExited)
				process.Kill(1, .KillChildren);
		}

		/// The process ended on its own: what it left running stays running (a post-build step
		/// that starts a program), so the job no longer ends it on close.
		public void Release()
		{
#if BF_PLATFORM_WINDOWS
			if (mJob != null && mAssigned)
			{
				uint8[cInfoSize] info = default;
				SetInformationJobObject(mJob, JobObjectExtendedLimitInformation, &info, cInfoSize);
			}
#else
			mReleased = true;
#endif
		}
	}
}
