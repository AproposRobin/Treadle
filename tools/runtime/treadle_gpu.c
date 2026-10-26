/*
 * treadle_gpu.c - GPU compute for [Kernel] functions (docs/GPU-Compute.md): the CUDA driver API,
 * loaded at run time from nvcuda.dll (Windows) or libcuda.so.1 (Linux, WSL included), so a program
 * has no link-time dependency on a GPU and runs the CPU path when there is none.
 *
 * The build driver appends this file to treadle_rt.c (one translation unit, the same flags), so it
 * may use the runtime's static helpers (rt_fatal). The functions the program reaches:
 *
 *   rt_gpu_register(ptx, sites, n, kernels, n)  the program's PTX module, its check sites and its
 *                                  kernels' names (a static constructor of the GPU unit the back end
 *                                  makes when the program has kernels)
 *   rt_gpu_available()             1 when a CUDA device, its driver and the module are usable; 0
 *                                  otherwise, or when TREADLE_GPU=cpu (the CPU path everywhere)
 *   rt_gpu_alloc / rt_gpu_alloc_zero / rt_gpu_free  a buffer: device memory, or host memory
 *                                  without a GPU
 *   rt_gpu_upload / rt_gpu_download  host <-> buffer copies (both wait for earlier launches)
 *   rt_gpu_host_alloc / rt_gpu_host_free  pinned host memory (PinnedBuffer)
 *   rt_gpu_stream_new / _free / _sync, rt_gpu_upload_async / rt_gpu_download_async  streams
 *   rt_gpu_launch(entry, kinds, count, block, stream, flags, a0..a7)  launches one PTX entry over
 *                                  `count` indices in blocks of `block`; 0 when there is no GPU (the
 *                                  caller runs the kernel on the CPU instead)
 *   rt_gpu_sync()                  waits for every launch
 *   rt_gpu_describe(buf, size)     a line naming the device, the driver and the PTX target
 *   rt_kernel_cpu(count, block, flags, chunk, a0..a7)  the CPU path over the thread pool, in whole
 *                                  blocks on fibers when the kernel uses Shared / Barrier
 *   rt_kernel_barrier(), rt_kernel_shared(key, bytes)  Kernel.Barrier and Kernel.Shared on the CPU
 *
 * A driver error is a fatal error naming the call and the driver's own text (cuGetErrorName and
 * cuGetErrorString), and for a module that does not load the JIT's error log, verbatim. A check
 * that failed in a kernel is reported from the device-side error record after every wait.
 */

#ifdef _WIN32
__declspec(dllimport) void* __stdcall LoadLibraryA(const char* name);
__declspec(dllimport) void* __stdcall GetProcAddress(void* module, const char* name);
#define RT_GPU_LIB "nvcuda.dll"
#define rt_gpu_dlopen(n) LoadLibraryA(n)
#define rt_gpu_dlsym(h, n) GetProcAddress(h, n)
#else
#include <dlfcn.h>
#define RT_GPU_LIB "libcuda.so.1"
#define rt_gpu_dlopen(n) dlopen(n, RTLD_NOW | RTLD_LOCAL)
#define rt_gpu_dlsym(h, n) dlsym(h, n)
#endif

/* The driver API types and entry points used (cuda.h is not needed: the toolkit is not installed;
   these are the documented C declarations of the driver API, CUDA 4.0 and later). */
typedef int rt_cu_result;
typedef int rt_cu_device;
typedef void* rt_cu_context;
typedef void* rt_cu_module;
typedef void* rt_cu_function;
typedef unsigned long long rt_cu_ptr;

#ifdef _WIN32
#define RT_CUDAAPI __stdcall
#else
#define RT_CUDAAPI
#endif

static struct
{
    rt_cu_result (RT_CUDAAPI *Init)(unsigned flags);
    rt_cu_result (RT_CUDAAPI *DriverGetVersion)(int* version);
    rt_cu_result (RT_CUDAAPI *DeviceGet)(rt_cu_device* dev, int ordinal);
    rt_cu_result (RT_CUDAAPI *DeviceGetCount)(int* count);
    rt_cu_result (RT_CUDAAPI *DeviceGetName)(char* name, int len, rt_cu_device dev);
    rt_cu_result (RT_CUDAAPI *DeviceGetAttribute)(int* value, int attrib, rt_cu_device dev);
    rt_cu_result (RT_CUDAAPI *PrimaryCtxRetain)(rt_cu_context* ctx, rt_cu_device dev);
    rt_cu_result (RT_CUDAAPI *CtxSetCurrent)(rt_cu_context ctx);
    rt_cu_result (RT_CUDAAPI *CtxSynchronize)(void);
    rt_cu_result (RT_CUDAAPI *ModuleLoadDataEx)(rt_cu_module* mod, const void* image, unsigned n, int* options, void** values);
    rt_cu_result (RT_CUDAAPI *ModuleGetFunction)(rt_cu_function* fn, rt_cu_module mod, const char* name);
    rt_cu_result (RT_CUDAAPI *MemAlloc)(rt_cu_ptr* p, size_t bytes);
    rt_cu_result (RT_CUDAAPI *MemFree)(rt_cu_ptr p);
    rt_cu_result (RT_CUDAAPI *MemcpyHtoD)(rt_cu_ptr dst, const void* src, size_t bytes);
    rt_cu_result (RT_CUDAAPI *MemcpyDtoH)(void* dst, rt_cu_ptr src, size_t bytes);
    rt_cu_result (RT_CUDAAPI *LaunchKernel)(rt_cu_function f, unsigned gx, unsigned gy, unsigned gz, unsigned bx, unsigned by,
                                            unsigned bz, unsigned shared, void* stream, void** params, void** extra);
    rt_cu_result (RT_CUDAAPI *MemsetD8)(rt_cu_ptr dst, unsigned char value, size_t n);
    rt_cu_result (RT_CUDAAPI *MemHostAlloc)(void** p, size_t bytes, unsigned flags);
    rt_cu_result (RT_CUDAAPI *MemFreeHost)(void* p);
    rt_cu_result (RT_CUDAAPI *StreamCreate)(void** stream, unsigned flags);
    rt_cu_result (RT_CUDAAPI *StreamDestroy)(void* stream);
    rt_cu_result (RT_CUDAAPI *StreamSynchronize)(void* stream);
    rt_cu_result (RT_CUDAAPI *MemcpyHtoDAsync)(rt_cu_ptr dst, const void* src, size_t bytes, void* stream);
    rt_cu_result (RT_CUDAAPI *MemcpyDtoHAsync)(void* dst, rt_cu_ptr src, size_t bytes, void* stream);
    rt_cu_result (RT_CUDAAPI *ModuleGetGlobal)(rt_cu_ptr* p, size_t* bytes, rt_cu_module mod, const char* name);
    rt_cu_result (RT_CUDAAPI *GetErrorName)(rt_cu_result r, const char** text);
    rt_cu_result (RT_CUDAAPI *GetErrorString)(rt_cu_result r, const char** text);
} rt_cu;

/* 0 not tried, 1 usable, -1 not usable (no driver, no device, TREADLE_GPU=cpu, or the module failed) */
static volatile int32_t rt_gpu_state;
static rt_cu_context rt_gpu_ctx;
static rt_cu_module rt_gpu_mod;
static const char* rt_gpu_ptx;
static int rt_gpu_driver_version;
static int rt_gpu_cc_major, rt_gpu_cc_minor;
static char rt_gpu_name[128];
static char rt_gpu_why[512];

static void rt_kernel_check_blocks(const char* what, int64_t count, int64_t block, int32_t flags);

/* The kernels already looked up in the module (by entry name; a program has a few). */
#define RT_GPU_MAX_KERNELS 64
static struct { const char* entry; rt_cu_function fn; } rt_gpu_kernels[RT_GPU_MAX_KERNELS];
static int rt_gpu_kernel_count;

/* The module's check sites ("<where>\x01<node>\x01<a Fatal node's message>", by the site numbers of
   the device-side error record) and its kernels (entry name, Type.Function pairs). */
static const char* const* rt_gpu_sites;
static int32_t rt_gpu_site_count;
static const char* const* rt_gpu_kernel_names;
static int32_t rt_gpu_kernel_name_count;
/* The device-side error record (@treadle_gpu_error: kind, site, a, b), and the kernels launched since
   the host last read it (the one named in a report; "one of" when several were). */
static rt_cu_ptr rt_gpu_err;
static const char* rt_gpu_last_entry;
static int32_t rt_gpu_several_entries;

void rt_gpu_register(const char* ptx, const char* const* sites, int32_t siteCount, const char* const* kernels, int32_t kernelCount)
{
    rt_gpu_ptx = ptx;
    rt_gpu_sites = sites;
    rt_gpu_site_count = siteCount;
    rt_gpu_kernel_names = kernels;
    rt_gpu_kernel_name_count = kernelCount;
}

static void rt_gpu_fail(const char* call, rt_cu_result r, const char* extra)
{
    const char* name = "?";
    const char* text = "";
    char msg[1536];
    if (rt_cu.GetErrorName) rt_cu.GetErrorName(r, &name);
    if (rt_cu.GetErrorString) rt_cu.GetErrorString(r, &text);
    snprintf(msg, sizeof msg, "GPU: %s failed: %s (%d): %s%s%s", call, name ? name : "?", r, text ? text : "",
             (extra && *extra) ? "; " : "", (extra && *extra) ? extra : "");
    rt_fatal(14, NULL, msg);
}

#define RT_CU_CHECK(call, expr) do { rt_cu_result rt_r_ = (expr); if (rt_r_ != 0) rt_gpu_fail(call, rt_r_, NULL); } while (0)

static int rt_gpu_unusable(const char* why)
{
    snprintf(rt_gpu_why, sizeof rt_gpu_why, "%s", why);
    rt_gpu_state = -1;
    return 0;
}

/* Loads the driver, opens device 0's primary context and the program's module, once. */
static int rt_gpu_open(void)
{
    if (rt_gpu_state != 0)
        return rt_gpu_state > 0;
    const char* mode = getenv("TREADLE_GPU");
    if (mode && strcmp(mode, "cpu") == 0)
        return rt_gpu_unusable("TREADLE_GPU=cpu");
    void* lib = rt_gpu_dlopen(RT_GPU_LIB);
    if (!lib)
        return rt_gpu_unusable("no CUDA driver (" RT_GPU_LIB " not found)");
#define RT_CU_SYM(field, name) \
    *(void**)&rt_cu.field = (void*)rt_gpu_dlsym(lib, name); \
    if (!rt_cu.field) return rt_gpu_unusable("the CUDA driver has no " name);
    RT_CU_SYM(Init, "cuInit")
    RT_CU_SYM(DriverGetVersion, "cuDriverGetVersion")
    RT_CU_SYM(DeviceGet, "cuDeviceGet")
    RT_CU_SYM(DeviceGetCount, "cuDeviceGetCount")
    RT_CU_SYM(DeviceGetName, "cuDeviceGetName")
    RT_CU_SYM(DeviceGetAttribute, "cuDeviceGetAttribute")
    RT_CU_SYM(PrimaryCtxRetain, "cuDevicePrimaryCtxRetain")
    RT_CU_SYM(CtxSetCurrent, "cuCtxSetCurrent")
    RT_CU_SYM(CtxSynchronize, "cuCtxSynchronize")
    RT_CU_SYM(ModuleLoadDataEx, "cuModuleLoadDataEx")
    RT_CU_SYM(ModuleGetFunction, "cuModuleGetFunction")
    RT_CU_SYM(MemAlloc, "cuMemAlloc_v2")
    RT_CU_SYM(MemFree, "cuMemFree_v2")
    RT_CU_SYM(MemcpyHtoD, "cuMemcpyHtoD_v2")
    RT_CU_SYM(MemcpyDtoH, "cuMemcpyDtoH_v2")
    RT_CU_SYM(LaunchKernel, "cuLaunchKernel")
    RT_CU_SYM(MemsetD8, "cuMemsetD8_v2")
    RT_CU_SYM(MemHostAlloc, "cuMemHostAlloc")
    RT_CU_SYM(MemFreeHost, "cuMemFreeHost")
    RT_CU_SYM(StreamCreate, "cuStreamCreate")
    RT_CU_SYM(StreamDestroy, "cuStreamDestroy_v2")
    RT_CU_SYM(StreamSynchronize, "cuStreamSynchronize")
    RT_CU_SYM(MemcpyHtoDAsync, "cuMemcpyHtoDAsync_v2")
    RT_CU_SYM(MemcpyDtoHAsync, "cuMemcpyDtoHAsync_v2")
    RT_CU_SYM(ModuleGetGlobal, "cuModuleGetGlobal_v2")
    RT_CU_SYM(GetErrorName, "cuGetErrorName")
    RT_CU_SYM(GetErrorString, "cuGetErrorString")
#undef RT_CU_SYM
    rt_cu_result r = rt_cu.Init(0);
    if (r != 0)
    {
        char why[128];
        snprintf(why, sizeof why, "cuInit failed (%d): no usable CUDA device", r);
        return rt_gpu_unusable(why);
    }
    rt_cu.DriverGetVersion(&rt_gpu_driver_version);
    int count = 0;
    if (rt_cu.DeviceGetCount(&count) != 0 || count < 1)
        return rt_gpu_unusable("no CUDA device");
    rt_cu_device dev;
    RT_CU_CHECK("cuDeviceGet", rt_cu.DeviceGet(&dev, 0));
    rt_cu.DeviceGetName(rt_gpu_name, (int)sizeof rt_gpu_name, dev);
    rt_cu.DeviceGetAttribute(&rt_gpu_cc_major, 75, dev); /* CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR */
    rt_cu.DeviceGetAttribute(&rt_gpu_cc_minor, 76, dev); /* ..._MINOR */
    if (rt_gpu_cc_major < 7 || (rt_gpu_cc_major == 7 && rt_gpu_cc_minor < 5))
        return rt_gpu_unusable("the GPU is older than sm_75 (the PTX target)");
    RT_CU_CHECK("cuDevicePrimaryCtxRetain", rt_cu.PrimaryCtxRetain(&rt_gpu_ctx, dev));
    RT_CU_CHECK("cuCtxSetCurrent", rt_cu.CtxSetCurrent(rt_gpu_ctx));
    if (rt_gpu_ptx)
    {
        /* the JIT's logs (CU_JIT_INFO_LOG_BUFFER 3, its size 4, CU_JIT_ERROR_LOG_BUFFER 5, its size 6) */
        static char info[4096], error[4096];
        int options[4] = { 3, 4, 5, 6 };
        void* values[4] = { info, (void*)(uintptr_t)sizeof info, error, (void*)(uintptr_t)sizeof error };
        r = rt_cu.ModuleLoadDataEx(&rt_gpu_mod, rt_gpu_ptx, 4, options, values);
        if (r != 0)
            rt_gpu_fail("cuModuleLoadDataEx (the program's PTX)", r, error);
        size_t bytes = 0;
        if (rt_cu.ModuleGetGlobal(&rt_gpu_err, &bytes, rt_gpu_mod, "treadle_gpu_error") != 0 || bytes < 16)
            rt_gpu_err = 0;
    }
    rt_gpu_state = 1;
    return 1;
}

/* Every entry point makes the context current on the calling thread (any Treadle thread may call). */
static int rt_gpu_enter(void)
{
    if (!rt_gpu_open())
        return 0;
    RT_CU_CHECK("cuCtxSetCurrent", rt_cu.CtxSetCurrent(rt_gpu_ctx));
    return 1;
}

/* After every wait on the device (Sync, a stream's Sync, a Download): reports a check that failed
   in a kernel (the device-side error record). */
static void rt_gpu_check_error(void)
{
    if (!rt_gpu_err || rt_gpu_state <= 0)
        return;
    int32_t rec[4] = { 0, 0, 0, 0 };
    RT_CU_CHECK("cuMemcpyDtoH (the GPU's error record)", rt_cu.MemcpyDtoH(rec, rt_gpu_err, sizeof rec));
    if (rec[0] == 0)
    {
        rt_gpu_last_entry = NULL;
        rt_gpu_several_entries = 0;
        return;
    }
    /* the site: where, node and a Fatal node's message */
    char where[256] = "?", node[64] = "?", fatalMsg[256] = "";
    if (rec[1] >= 0 && rec[1] < rt_gpu_site_count && rt_gpu_sites)
    {
        const char* s = rt_gpu_sites[rec[1]];
        const char* a = strchr(s, '\x01');
        const char* b = a ? strchr(a + 1, '\x01') : NULL;
        if (a && b)
        {
            snprintf(where, sizeof where, "%.*s", (int)(a - s), s);
            snprintf(node, sizeof node, "%.*s", (int)(b - a - 1), a + 1);
            snprintf(fatalMsg, sizeof fatalMsg, "%s", b + 1);
        }
    }
    char what[320];
    switch (rec[0])
    {
    case 1: snprintf(what, sizeof what, "null reference"); break;
    case 2: snprintf(what, sizeof what, "index %d out of range (length %d)", rec[2], rec[3]); break;
    case 3: snprintf(what, sizeof what, "span from %d out of range (length %d)", rec[2], rec[3]); break;
    case 4: snprintf(what, sizeof what, "use of a deleted object"); break;
    case 5:
        if (fatalMsg[0])
            snprintf(what, sizeof what, "%s", fatalMsg);
        else
            snprintf(what, sizeof what, "fatal error %d", rec[2]);
        break;
    case 6: snprintf(what, sizeof what, "local array of a negative length (%d)", rec[2]); break;
    case 7: snprintf(what, sizeof what, "call of an abstract function"); break;
    default: snprintf(what, sizeof what, "a check failed (kind %d)", rec[0]); break;
    }
    /* the kernel: the one launched since the last wait */
    const char* kernel = NULL;
    for (int32_t i = 0; rt_gpu_last_entry && i < rt_gpu_kernel_name_count; i++)
        if (strcmp(rt_gpu_kernel_names[2 * i], rt_gpu_last_entry) == 0)
            kernel = rt_gpu_kernel_names[2 * i + 1];
    char msg[1024];
    if (rec[1] >= 0)
        snprintf(msg, sizeof msg, "GPU: %s at %s node %s%s%s%s", what, where, node, kernel ? (rt_gpu_several_entries ? " (in one of the kernels launched since the last wait, the last " : " (in the kernel ") : "",
                 kernel ? kernel : "", kernel ? ")" : "");
    else
        snprintf(msg, sizeof msg, "GPU: %s%s%s%s", what, kernel ? " (in the kernel " : "", kernel ? kernel : "", kernel ? ")" : "");
    rt_fatal(14, NULL, msg);
}

int32_t rt_gpu_available(void)
{
    return rt_gpu_open();
}

void* rt_gpu_alloc(int64_t bytes)
{
    if (bytes < 0)
        rt_fatal(11, NULL, "GPU buffer of a negative size");
    if (!rt_gpu_enter())
        return calloc(1, (size_t)(bytes ? bytes : 1));
    rt_cu_ptr p = 0;
    RT_CU_CHECK("cuMemAlloc", rt_cu.MemAlloc(&p, (size_t)(bytes ? bytes : 1)));
    return (void*)(uintptr_t)p;
}

/* A buffer set to zero (Gpu.Alloc): rt_gpu_alloc's memory, cleared on the device. */
void* rt_gpu_alloc_zero(int64_t bytes)
{
    void* p = rt_gpu_alloc(bytes);
    if (rt_gpu_state > 0)
        RT_CU_CHECK("cuMemsetD8", rt_cu.MemsetD8((rt_cu_ptr)(uintptr_t)p, 0, (size_t)(bytes ? bytes : 1)));
    return p;
}

/* Page-locked host memory (PinnedBuffer): the GPU copies from and to it by DMA at the bus's speed,
   and an async copy over it does not hold up the host. Zeroed. calloc's memory without a GPU. */
void* rt_gpu_host_alloc(int64_t bytes)
{
    if (bytes < 0)
        rt_fatal(11, NULL, "pinned buffer of a negative size");
    if (!rt_gpu_enter())
        return calloc(1, (size_t)(bytes ? bytes : 1));
    void* p = NULL;
    RT_CU_CHECK("cuMemHostAlloc", rt_cu.MemHostAlloc(&p, (size_t)(bytes ? bytes : 1), 0));
    memset(p, 0, (size_t)(bytes ? bytes : 1));
    return p;
}

void rt_gpu_host_free(void* p)
{
    if (!p)
        return;
    if (rt_gpu_state <= 0)
    {
        free(p);
        return;
    }
    rt_gpu_enter();
    RT_CU_CHECK("cuMemFreeHost", rt_cu.MemFreeHost(p));
}

/* Streams (GpuStream): copies and launches queued in order, running beside the host and the other
   streams. Null without a GPU: everything then runs at once, in order, on the host. */
void* rt_gpu_stream_new(void)
{
    if (!rt_gpu_enter())
        return NULL;
    void* s = NULL;
    RT_CU_CHECK("cuStreamCreate", rt_cu.StreamCreate(&s, 1)); /* CU_STREAM_NON_BLOCKING */
    return s;
}

void rt_gpu_stream_sync(void* s)
{
    if (!s || rt_gpu_state <= 0)
        return;
    rt_gpu_enter();
    RT_CU_CHECK("cuStreamSynchronize", rt_cu.StreamSynchronize(s));
    rt_gpu_check_error();
}

/* Deleting a stream waits for what it still has queued. */
void rt_gpu_stream_free(void* s)
{
    if (!s || rt_gpu_state <= 0)
        return;
    rt_gpu_stream_sync(s);
    RT_CU_CHECK("cuStreamDestroy", rt_cu.StreamDestroy(s));
}

/* Async copies on a stream: they return at once; the host memory must stay as it is until the
   stream's Sync (pinned memory makes them truly async; pageable memory is staged by the driver). */
void rt_gpu_upload_async(void* dst, const void* src, int64_t bytes, void* stream)
{
    if (bytes <= 0)
        return;
    if (rt_gpu_state <= 0)
    {
        memcpy(dst, src, (size_t)bytes);
        return;
    }
    rt_gpu_enter();
    RT_CU_CHECK("cuMemcpyHtoDAsync", rt_cu.MemcpyHtoDAsync((rt_cu_ptr)(uintptr_t)dst, src, (size_t)bytes, stream));
}

void rt_gpu_download_async(void* dst, const void* src, int64_t bytes, void* stream)
{
    if (bytes <= 0)
        return;
    if (rt_gpu_state <= 0)
    {
        memcpy(dst, src, (size_t)bytes);
        return;
    }
    rt_gpu_enter();
    RT_CU_CHECK("cuMemcpyDtoHAsync", rt_cu.MemcpyDtoHAsync(dst, (rt_cu_ptr)(uintptr_t)src, (size_t)bytes, stream));
}

void rt_gpu_free(void* p)
{
    if (!p)
        return;
    if (rt_gpu_state <= 0)
    {
        free(p);
        return;
    }
    rt_gpu_enter();
    RT_CU_CHECK("cuMemFree", rt_cu.MemFree((rt_cu_ptr)(uintptr_t)p));
}

void rt_gpu_upload(void* dst, const void* src, int64_t bytes)
{
    if (bytes <= 0)
        return;
    if (rt_gpu_state <= 0)
    {
        memcpy(dst, src, (size_t)bytes);
        return;
    }
    rt_gpu_enter();
    RT_CU_CHECK("cuMemcpyHtoD", rt_cu.MemcpyHtoD((rt_cu_ptr)(uintptr_t)dst, src, (size_t)bytes));
}

void rt_gpu_download(void* dst, const void* src, int64_t bytes)
{
    if (bytes <= 0)
        return;
    if (rt_gpu_state <= 0)
    {
        memcpy(dst, src, (size_t)bytes);
        return;
    }
    rt_gpu_enter();
    RT_CU_CHECK("cuMemcpyDtoH", rt_cu.MemcpyDtoH(dst, (rt_cu_ptr)(uintptr_t)src, (size_t)bytes));
    rt_gpu_check_error();
}

void rt_gpu_sync(void)
{
    if (rt_gpu_state <= 0)
        return;
    rt_gpu_enter();
    RT_CU_CHECK("cuCtxSynchronize", rt_cu.CtxSynchronize());
    rt_gpu_check_error();
}

/* `kinds`: one letter per kernel parameter: 'S' a span (16 bytes: the device pointer and the count,
   two PTX parameters), 'v' any other value (one PTX parameter, read from its address). The PTX
   entry takes the count first. */
int32_t rt_gpu_launch(const char* entry, const char* kinds, int64_t count, int64_t block, void* stream, int32_t flags,
                      void* a0, void* a1, void* a2, void* a3, void* a4, void* a5, void* a6, void* a7)
{
    if (block < 1 || block > 1024)
        rt_fatal(14, NULL, "GPU: the block size is not 1 to 1024");
    rt_kernel_check_blocks("Gpu.Dispatch", count, block, flags);
    if (!rt_gpu_enter())
        return 0;
    if (!rt_gpu_mod)
        rt_fatal(14, NULL, "GPU: the program has no PTX module (no kernel was compiled for the GPU)");
    if (count <= 0)
        return 1;
    rt_cu_function fn = NULL;
    for (int i = 0; i < rt_gpu_kernel_count; i++)
        if (strcmp(rt_gpu_kernels[i].entry, entry) == 0)
            fn = rt_gpu_kernels[i].fn;
    if (!fn)
    {
        rt_cu_result r = rt_cu.ModuleGetFunction(&fn, rt_gpu_mod, entry);
        if (r != 0)
        {
            char what[256];
            snprintf(what, sizeof what, "cuModuleGetFunction(%s)", entry);
            rt_gpu_fail(what, r, NULL);
        }
        if (rt_gpu_kernel_count < RT_GPU_MAX_KERNELS)
        {
            rt_gpu_kernels[rt_gpu_kernel_count].entry = entry;
            rt_gpu_kernels[rt_gpu_kernel_count].fn = fn;
            rt_gpu_kernel_count++;
        }
    }
    if (rt_gpu_last_entry && strcmp(rt_gpu_last_entry, entry) != 0)
        rt_gpu_several_entries = 1;
    rt_gpu_last_entry = entry;
    void* args[8] = { a0, a1, a2, a3, a4, a5, a6, a7 };
    void* params[1 + 16];
    int n = 0;
    params[n++] = &count;
    for (int i = 0; kinds[i] && i < 8; i++)
    {
        if (kinds[i] == 'S')
        {
            params[n++] = args[i];
            params[n++] = (char*)args[i] + 8;
        }
        else
            params[n++] = args[i];
    }
    int64_t groups = (count + block - 1) / block;
    if (groups > 0x7FFFFFFF)
        rt_fatal(14, NULL, "GPU: the dispatch count is too large for one launch");
    RT_CU_CHECK("cuLaunchKernel", rt_cu.LaunchKernel(fn, (unsigned)groups, 1, 1, (unsigned)block, 1, 1, 0, stream, params, NULL));
    return 1;
}

/* A line for the program's log: the device, its compute capability, the driver API version and the
   PTX target the module was built for, or why the GPU is not used. */
void rt_gpu_describe(char* buf, int64_t size)
{
    if (!buf || size <= 0)
        return;
    if (!rt_gpu_open())
    {
        snprintf(buf, (size_t)size, "no GPU: %s", rt_gpu_why);
        return;
    }
    const char* ver = rt_gpu_ptx ? strstr(rt_gpu_ptx, ".version ") : NULL;
    const char* target = rt_gpu_ptx ? strstr(rt_gpu_ptx, ".target ") : NULL;
    int vlen = 0, tlen = 0;
    while (ver && ver[vlen] && ver[vlen] != '\n' && ver[vlen] != '\r') vlen++;
    while (target && target[tlen] && target[tlen] != '\n' && target[tlen] != '\r') tlen++;
    snprintf(buf, (size_t)size, "%s (sm_%d%d), CUDA driver API %d.%d, PTX %.*s %.*s loaded", rt_gpu_name, rt_gpu_cc_major,
             rt_gpu_cc_minor, rt_gpu_driver_version / 1000, (rt_gpu_driver_version % 1000) / 10, vlen, ver ? ver : "",
             tlen, target ? target : "");
}

void rt_gpu_print_info(void)
{
    char line[768];
    rt_gpu_describe(line, sizeof line);
    fflush(stdout);
    fprintf(stderr, "GPU: %s\n", line);
    fflush(stderr);
}

/* ---- the CPU path of a dispatch (Kernel.RunCpu, and Gpu.Dispatch without a GPU) ----------------
   The lowering gives a chunk function `chunk(args, lo, hi, block)` that runs the kernel for lo ..< hi
   (Kernel.SetBlockSize(block) once, Kernel.SetIndex(i) before each run: stores to thread-locals the
   program itself defines) and the addresses of the kernel's inputs. rt_kernel_cpu cuts 0 ..< count
   into chunks over the thread pool, as
   Parallel.ForRange does (the calling thread takes chunks too); TREADLE_KERNEL_THREADS=1 runs every
   index on the calling thread. Debug checks stay in the kernel: a failed one is a fatal error on the
   thread that ran it. */

typedef void (*rt_kernel_chunk_fn)(void** args, int64_t lo, int64_t hi, int64_t block);

typedef struct
{
    rt_kernel_chunk_fn chunk;
    void** args;
    int64_t block;
    int32_t flags;
} rt_kernel_job;

/* The fewest indices worth handing to the pool. */
#define RT_KERNEL_POOL_MIN 4096

static int rt_kernel_one_thread(void)
{
    static volatile int32_t mode; /* 0 not read, 1 pool, 2 one thread */
    if (mode == 0)
    {
        const char* t = getenv("TREADLE_KERNEL_THREADS");
        mode = (t && strcmp(t, "1") == 0) ? 2 : 1;
    }
    return mode == 2;
}

/* A dispatch of a kernel that uses Kernel.Shared or Kernel.Barrier (flags & 1) runs in whole
   blocks: its count is a multiple of the block size (the same rule on the GPU). */
static void rt_kernel_check_blocks(const char* what, int64_t count, int64_t block, int32_t flags)
{
    if ((flags & 1) && count % block != 0)
    {
        char msg[256];
        snprintf(msg, sizeof msg, "%s: the kernel uses Kernel.Shared or Kernel.Barrier, so the count (%lld) must be a multiple of the block size (%lld)",
                 what, (long long)count, (long long)block);
        rt_fatal(14, NULL, msg);
    }
}

/* Parallel.ForRange's body: one chunk of indices. */
static void rt_kernel_range(void* target, int64_t lo, int64_t hi)
{
    rt_kernel_job* j = (rt_kernel_job*)target;
    j->chunk(j->args, lo, hi, j->block);
}


/* ---- whole blocks on the CPU: Kernel.Shared and Kernel.Barrier ------------------------------
   A kernel that uses them (flags & 1) runs block by block. The threads of a block are fibers of the
   OS thread that runs the block (Win32 fibers; on Linux a small x86-64 stack switch): each fiber runs
   the kernel for one index; Kernel.Barrier switches back to the block's scheduler, which resumes the
   fibers in turn, so every fiber has reached the barrier (or finished) before any goes past it.
   Kernel.Shared gives each call site its own zeroed memory per block (keyed by a private global of
   the site), at most RT_KERNEL_SHARED_MAX bytes per block, as on the GPU. The fibers and the shared
   arena of an OS thread are made on its first block and kept. */

#define RT_KERNEL_SHARED_MAX 49152
#define RT_KERNEL_SHARED_SITES 64
#define RT_KERNEL_FIBER_STACK (256 * 1024)

#ifdef _WIN32
__declspec(dllimport) void* __stdcall ConvertThreadToFiber(void* param);
__declspec(dllimport) void* __stdcall CreateFiberEx(size_t commit, size_t reserve, unsigned long flags,
                                                     void (__stdcall *start)(void*), void* param);
__declspec(dllimport) void __stdcall SwitchToFiber(void* fiber);
__declspec(dllimport) int __stdcall IsThreadAFiber(void);
/* GetCurrentFiber is an inline function of winnt.h, not an export: the TEB's FiberData (x64). */
static void* rt_kf_current_fiber(void)
{
    void* f;
    __asm__ volatile("movq %%gs:0x20, %0" : "=r"(f));
    return f;
}
typedef void* rt_kf_ctx;
#else
#include <sys/mman.h>
/* The stack switch: saves the callee-saved registers on the current stack, stores its pointer in
   *save, loads `to`, restores the registers from there and returns into that context. */
__asm__(".text\n"
        ".p2align 4\n"
        ".hidden rt_kf_switch\n"
        ".globl rt_kf_switch\n"
        ".type rt_kf_switch,@function\n"
        "rt_kf_switch:\n"
        "  pushq %rbp\n  pushq %rbx\n  pushq %r12\n  pushq %r13\n  pushq %r14\n  pushq %r15\n"
        "  movq %rsp, (%rdi)\n"
        "  movq %rsi, %rsp\n"
        "  popq %r15\n  popq %r14\n  popq %r13\n  popq %r12\n  popq %rbx\n  popq %rbp\n"
        "  ret\n"
        ".size rt_kf_switch, .-rt_kf_switch\n");
void rt_kf_switch(void** save, void* to);
typedef void* rt_kf_ctx; /* a saved stack pointer */
#endif

typedef struct
{
    rt_kf_ctx ctx;           /* Win32: the fiber; Linux: the saved stack pointer */
    int64_t index;           /* the global index it runs */
    int32_t done;
} rt_kf;

typedef struct
{
    rt_kf_ctx main;          /* the scheduler (the OS thread itself) */
    rt_kf* fibers;
    int32_t count;           /* fibers made */
    int32_t cur;             /* the fiber running, -1 in the scheduler */
    rt_kernel_job* job;      /* the dispatch whose block runs, null outside one */
    char* shared;            /* the block's shared arena */
    int64_t sharedUsed;
    const void* sharedKeys[RT_KERNEL_SHARED_SITES];
    char* sharedAt[RT_KERNEL_SHARED_SITES];
    int32_t sharedCount;
} rt_kf_thread;

static _Thread_local rt_kf_thread* rt_kf_self;

/* Back to the scheduler (a barrier, or the end of the fiber's index). */
static void rt_kf_yield(rt_kf_thread* t)
{
    rt_kf* f = &t->fibers[t->cur];
#ifdef _WIN32
    (void)f;
    SwitchToFiber(t->main);
#else
    rt_kf_switch(&f->ctx, t->main);
#endif
}

/* A fiber's life: run the kernel for the index the scheduler gave it, report done, wait for the
   next block. */
static void rt_kf_body(rt_kf_thread* t)
{
    for (;;)
    {
        rt_kf* f = &t->fibers[t->cur];
        rt_kernel_job* j = t->job;
        j->chunk(j->args, f->index, f->index + 1, j->block);
        f->done = 1;
        rt_kf_yield(t);
    }
}

#ifdef _WIN32
static void __stdcall rt_kf_start(void* param)
{
    rt_kf_body((rt_kf_thread*)param);
}
#else
static void rt_kf_start(void)
{
    rt_kf_body(rt_kf_self);
}
#endif

static rt_kf_thread* rt_kf_thread_get(void)
{
    rt_kf_thread* t = rt_kf_self;
    if (t)
        return t;
    t = (rt_kf_thread*)calloc(1, sizeof(rt_kf_thread));
    if (t)
        t->shared = (char*)malloc(RT_KERNEL_SHARED_MAX);
    if (!t || !t->shared)
        rt_fatal(11, NULL, "Kernel: out of memory for a block's shared memory");
    t->cur = -1;
#ifdef _WIN32
    t->main = IsThreadAFiber() ? rt_kf_current_fiber() : ConvertThreadToFiber(NULL);
    if (!t->main)
        rt_fatal(14, NULL, "Kernel: the thread could not become a fiber (ConvertThreadToFiber failed)");
#endif
    rt_kf_self = t;
    return t;
}

/* At least n fibers on this thread. */
static void rt_kf_ensure(rt_kf_thread* t, int32_t n)
{
    if (t->count >= n)
        return;
    rt_kf* more = (rt_kf*)realloc(t->fibers, sizeof(rt_kf) * (size_t)n);
    if (!more)
        rt_fatal(11, NULL, "Kernel: out of memory for a block's fibers");
    t->fibers = more;
    for (int32_t i = t->count; i < n; i++)
    {
        rt_kf* f = &t->fibers[i];
        memset(f, 0, sizeof *f);
#ifdef _WIN32
        f->ctx = CreateFiberEx(0, RT_KERNEL_FIBER_STACK, 1 /* FIBER_FLAG_FLOAT_SWITCH */, rt_kf_start, t);
        if (!f->ctx)
            rt_fatal(14, NULL, "Kernel: a block's fiber could not be made (CreateFiberEx failed)");
#else
        char* stack = (char*)mmap(NULL, RT_KERNEL_FIBER_STACK, PROT_READ | PROT_WRITE,
                                  MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_STACK, -1, 0);
        if (stack == (char*)MAP_FAILED)
            rt_fatal(14, NULL, "Kernel: a block's fiber stack could not be mapped");
        mprotect(stack, 4096, PROT_NONE); /* a guard page */
        void** sp = (void**)(((uintptr_t)(stack + RT_KERNEL_FIBER_STACK)) & ~(uintptr_t)15);
        *--sp = NULL;                    /* rt_kf_start's return address (it never returns) */
        *--sp = (void*)rt_kf_start;      /* where rt_kf_switch's ret goes */
        for (int r = 0; r < 6; r++)
            *--sp = NULL;                /* rbp rbx r12 r13 r14 r15 */
        f->ctx = sp;
#endif
    }
    t->count = n;
}

/* Runs blocks b0 ..< b1 of the job on this thread. */
static void rt_kernel_blocks(rt_kernel_job* j, int64_t b0, int64_t b1)
{
    rt_kf_thread* t = rt_kf_thread_get();
    int32_t n = (int32_t)j->block;
    rt_kf_ensure(t, n);
    rt_kernel_job* outer = t->job;
    if (outer)
        rt_fatal(14, NULL, "Kernel: a block dispatch inside a block dispatch on the same thread");
    t->job = j;
    for (int64_t b = b0; b < b1; b++)
    {
        t->sharedUsed = 0;
        t->sharedCount = 0;
        for (int32_t i = 0; i < n; i++)
        {
            t->fibers[i].index = b * j->block + i;
            t->fibers[i].done = 0;
        }
        int32_t left = n;
        while (left > 0)
        {
            for (int32_t i = 0; i < n; i++)
            {
                rt_kf* f = &t->fibers[i];
                if (f->done)
                    continue;
                t->cur = i;
#ifdef _WIN32
                SwitchToFiber(f->ctx);
#else
                rt_kf_switch(&t->main, f->ctx);
#endif
                t->cur = -1;
                if (f->done)
                    left--;
            }
        }
    }
    t->job = NULL;
}

static void rt_kernel_block_range(void* target, int64_t lo, int64_t hi)
{
    rt_kernel_blocks((rt_kernel_job*)target, lo, hi);
}

void rt_kernel_barrier(void)
{
    rt_kf_thread* t = rt_kf_self;
    if (!t || !t->job || t->cur < 0)
        rt_fatal(14, NULL, "Kernel.Barrier outside a kernel's dispatch (or in a kernel that was not built for blocks)");
    rt_kf_yield(t);
}

/* Kernel.Shared on the CPU: the block's memory for the call site `key` (zeroed on its first use in
   the block). */
void* rt_kernel_shared(const void* key, int64_t bytes)
{
    rt_kf_thread* t = rt_kf_self;
    if (!t || !t->job)
        rt_fatal(14, NULL, "Kernel.Shared outside a kernel's dispatch");
    for (int32_t i = 0; i < t->sharedCount; i++)
        if (t->sharedKeys[i] == key)
            return t->sharedAt[i];
    int64_t at = (t->sharedUsed + 15) & ~(int64_t)15;
    if (bytes < 0 || at + bytes > RT_KERNEL_SHARED_MAX || t->sharedCount >= RT_KERNEL_SHARED_SITES)
        rt_fatal(14, NULL, "Kernel.Shared: more than 48 KB of shared memory in one block");
    char* p = t->shared + at;
    memset(p, 0, (size_t)bytes);
    t->sharedUsed = at + bytes;
    t->sharedKeys[t->sharedCount] = key;
    t->sharedAt[t->sharedCount] = p;
    t->sharedCount++;
    return p;
}

void rt_kernel_cpu(int64_t count, int64_t block, int32_t flags, void* chunk, void* a0, void* a1, void* a2, void* a3,
                   void* a4, void* a5, void* a6, void* a7)
{
    if (block < 1 || block > 1024)
        rt_fatal(14, NULL, "Kernel.RunCpu: the block size is not 1 to 1024");
    if (count <= 0)
        return;
    rt_kernel_check_blocks("Kernel.RunCpu", count, block, flags);
    void* args[8] = { a0, a1, a2, a3, a4, a5, a6, a7 };
    rt_kernel_job job = { (rt_kernel_chunk_fn)chunk, args, block, flags };
    int one = rt_kernel_one_thread() || count < RT_KERNEL_POOL_MIN;
    if (flags & 1)
    {
        int64_t blocks = count / block;
        if (one || blocks < 2)
        {
            rt_kernel_blocks(&job, 0, blocks);
            return;
        }
        void* body[3] = { NULL, &job, (void*)rt_kernel_block_range };
        rt_parallel_ranges(0, blocks, body);
        return;
    }
    if (one)
    {
        rt_kernel_range(&job, 0, count);
        return;
    }
    /* a delegate as the pool sees one: [1] the target, [2] the function */
    void* body[3] = { NULL, &job, (void*)rt_kernel_range };
    rt_parallel_ranges(0, count, body);
}
