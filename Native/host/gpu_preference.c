/* Treadle.exe exports for hybrid-graphics laptops (NVIDIA Optimus, AMD PowerXpress): the drivers read these two
   values from the executable's export table when the process starts and then run it on the discrete GPU, so the
   editor is not moved between GPUs while it runs (a switch can leave its drawing context lost). They must be
   initialised data in the file, which a Beef static field is not (Beef sets it at run time), so this object file is
   linked into the editor (TreadleEditor/BeefProj.toml, Windows configurations). Built by Native\build_windows.ps1
   into Native\bin\win64\gpu_preference.obj. Windows Settings > System > Display > Graphics overrides the choice per
   app (docs/Known-Issues.md). */
__declspec(dllexport) unsigned long NvOptimusEnablement = 1;
__declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
