using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace Treadle.Debug.Dap
{
	/// A running program the debugger can attach to.
	class RunningProgram
	{
		public int32 Pid;
		/// The full path of its executable.
		public String Path = new .() ~ delete _;
		/// A library of the folder the process has loaded (a host of a `kind library` build); "" for
		/// a program of the folder itself.
		public String Module = new .() ~ delete _;
	}

	/// The running processes whose executable is in a folder, or that loaded a library of that folder
	/// (Debug > Attach to Process lists the project's `build/Debug` programs and the hosts of its library).
	static class ProcessList
	{
#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* OpenProcess(uint32 access, int32 inherit, uint32 pid);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 QueryFullProcessImageNameW(void* process, uint32 flags, char16* name, uint32* size);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 CloseHandle(void* handle);

		[CRepr]
		struct ModuleEntry32W
		{
			public uint32 dwSize;
			public uint32 th32ModuleID;
			public uint32 th32ProcessID;
			public uint32 GlblcntUsage;
			public uint32 ProccntUsage;
			public uint8* modBaseAddr;
			public uint32 modBaseSize;
			public void* hModule;
			public char16[256] szModule;
			public char16[260] szExePath;
		}

		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* CreateToolhelp32Snapshot(uint32 flags, uint32 pid);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 Module32FirstW(void* snapshot, ModuleEntry32W* entry);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 Module32NextW(void* snapshot, ModuleEntry32W* entry);

		/// The full paths of the modules (exe and DLLs) a process has loaded; nothing when they
		/// cannot be read (another user's or a protected process).
		static void Modules(int32 pid, List<String> outPaths)
		{
			// TH32CS_SNAPMODULE
			let snap = CreateToolhelp32Snapshot(0x8, (uint32)pid);
			if (snap == null || snap == (void*)(int)(-1))
				return;
			ModuleEntry32W e = default;
			e.dwSize = (uint32)sizeof(ModuleEntry32W);
			var ok = Module32FirstW(snap, &e) != 0;
			while (ok)
			{
				int n = 0;
				while (n < 260 && e.szExePath[n] != 0)
					n++;
				String path = new .();
				UTF16.Decode(Span<char16>(&e.szExePath, n), path);
				outPaths.Add(path);
				ok = Module32NextW(snap, &e) != 0;
			}
			CloseHandle(snap);
		}

		/// The executable of a process ("" when it cannot be opened).
		public static void ExePath(int32 pid, String outPath)
		{
			// PROCESS_QUERY_LIMITED_INFORMATION
			let h = OpenProcess(0x1000, 0, (uint32)pid);
			if (h == null)
				return;
			char16[1024] buf = ?;
			uint32 size = 1024;
			if (QueryFullProcessImageNameW(h, 0, &buf, &size) != 0)
				UTF16.Decode(Span<char16>(&buf, (int)size), outPath);
			CloseHandle(h);
		}
#else
		[CLink] static extern int readlink(char8* path, char8* buf, int size);

		public static void ExePath(int32 pid, String outPath)
		{
			char8[4096] buf = ?;
			String link = scope $"/proc/{pid}/exe";
			let n = readlink(link.CStr(), &buf, 4095);
			if (n > 0)
				outPath.Append(&buf, n);
		}

		/// The files a process has mapped (/proc/<pid>/maps: its executable and shared objects).
		static void Modules(int32 pid, List<String> outPaths)
		{
			String text = scope .();
			if (File.ReadAllText(scope $"/proc/{pid}/maps", text) case .Err)
				return;
			for (let line in text.Split('\n'))
			{
				let slash = line.IndexOf('/');
				if (slash < 0)
					continue;
				StringView path = line.Substring(slash);
				bool seen = false;
				for (let p in outPaths)
					if (p == path)
						seen = true;
				if (!seen)
					outPaths.Add(new String(path));
			}
		}
#endif

		/// A library file of a build folder: `<Name>.dll` (Windows), `lib<Name>.so` (Linux).
		static bool IsLibrary(StringView name)
		{
#if BF_PLATFORM_WINDOWS
			return name.EndsWith(".dll", .OrdinalIgnoreCase);
#else
			return name.StartsWith("lib") && name.EndsWith(".so");
#endif
		}

		static void Normal(StringView path, String outPath)
		{
			outPath.Append(path);
			outPath.Replace('\\', '/');
			while (outPath.EndsWith('/'))
				outPath.RemoveFromEnd(1);
#if BF_PLATFORM_WINDOWS
			outPath.ToLower();
#endif
		}

		/// The processes whose executable file is directly in `folder`, by process id.
		public static void FindIn(StringView folder, List<RunningProgram> outPrograms)
		{
			String dir = scope .();
			Normal(folder, dir);
			// the executables of the folder, by file name
			HashSet<String> names = scope .();
			defer { for (let n in names) delete n; }
			// the libraries of the folder (a `kind library` build), by normalised full path
			HashSet<String> libs = scope .();
			defer { for (let n in libs) delete n; }
			if (Directory.Exists(folder))
				for (let e in Directory.EnumerateFiles(folder))
				{
					String name = scope .();
					e.GetFileName(name);
					if (IsLibrary(name))
					{
						String full = new .();
						Normal(scope $"{dir}/{name}", full);
						libs.Add(full);
						continue;
					}
#if BF_PLATFORM_WINDOWS
					if (!name.EndsWith(".exe", .OrdinalIgnoreCase))
						continue;
					name.ToLower();
#else
					if (name.Contains('.'))
						continue;
#endif
					names.Add(new String(name));
				}
			if (names.IsEmpty && libs.IsEmpty)
				return;
			let self = Process.CurrentId;
			List<Process> procs = scope .();
			defer { ClearAndDeleteItems!(procs); }
			if (Process.GetProcesses(procs) case .Err)
				return;
			for (let p in procs)
			{
				let pid = p.Id;
				if (pid == self || pid <= 0)
					continue;
				String exe = scope .();
				ExePath(pid, exe);
				if (exe.IsEmpty)
					continue;
				String exeDir = scope .();
				Path.GetDirectoryPath(exe, exeDir);
				String nd = scope .();
				Normal(exeDir, nd);
				String file = scope .();
				Path.GetFileName(exe, file);
#if BF_PLATFORM_WINDOWS
				file.ToLower();
#endif
				if (nd == dir && names.Contains(file))
				{
					RunningProgram r = new .();
					r.Pid = pid;
					r.Path.Set(exe);
					outPrograms.Add(r);
					continue;
				}
				if (libs.IsEmpty)
					continue;
				// a host: a program from elsewhere that loaded one of the folder's libraries
				List<String> mods = scope .();
				defer { ClearAndDeleteItems!(mods); }
				Modules(pid, mods);
				for (let m in mods)
				{
					String nm = scope .();
					Normal(m, nm);
					if (!libs.Contains(nm))
						continue;
					RunningProgram r = new .();
					r.Pid = pid;
					r.Path.Set(exe);
					r.Module.Set(m);
					outPrograms.Add(r);
					break;
				}
			}
			outPrograms.Sort(scope (a, b) => a.Pid <=> b.Pid);
		}
	}
}
