// Live system power via IOReport energy counters + SMC PSTR.
// Same sources as macmon / powermetrics. No sudo.
//
// Protocol: each stdin line triggers one sample. Prints one JSON object:
//   {"ok":true,"cpu":1.23,"gpu":0.10,"ane":0.00,"all":1.33,"sys":5.80}
// First sample waits ~50ms so the energy delta is real. Later samples use
// elapsed time since the previous call (Ruby owns the cadence).

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

typedef struct IOReportSubscription *IOReportSubscriptionRef;

extern CFDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b);
extern IOReportSubscriptionRef IOReportCreateSubscription(
    void *a, CFMutableDictionaryRef b, CFMutableDictionaryRef *c, uint64_t d, CFTypeRef e);
extern CFDictionaryRef IOReportCreateSamples(
    IOReportSubscriptionRef a, CFMutableDictionaryRef b, CFTypeRef c);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef a, CFDictionaryRef b, CFTypeRef c);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef a);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef a);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef a);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef a, int32_t b);

typedef struct {
  uint8_t major;
  uint8_t minor;
  uint8_t build;
  uint8_t reserved;
  uint16_t release;
} SMCKeyDataVers;

typedef struct {
  uint16_t version;
  uint16_t length;
  uint32_t cpu_p_limit;
  uint32_t gpu_p_limit;
  uint32_t mem_p_limit;
} SMCKeyDataPLimit;

typedef struct {
  uint32_t data_size;
  uint32_t data_type;
  uint8_t data_attributes;
} SMCKeyDataKeyInfo;

typedef struct {
  uint32_t key;
  SMCKeyDataVers vers;
  SMCKeyDataPLimit p_limit_data;
  SMCKeyDataKeyInfo key_info;
  uint8_t result;
  uint8_t status;
  uint8_t data8;
  uint32_t data32;
  uint8_t bytes[32];
} SMCKeyData;

static IOReportSubscriptionRef g_subs = NULL;
static CFMutableDictionaryRef g_chans = NULL;
static CFDictionaryRef g_prev = NULL;
static uint64_t g_prev_ns = 0;
static io_connect_t g_smc = 0;
static SMCKeyDataKeyInfo g_pstr_info;
static int g_pstr_ok = 0;

static uint64_t monotonic_ns(void) {
  static mach_timebase_info_data_t info;
  static int inited = 0;
  if (!inited) {
    mach_timebase_info(&info);
    inited = 1;
  }
  return mach_absolute_time() * info.numer / info.denom;
}

static void cfstr_copy(CFStringRef s, char *buf, size_t n) {
  buf[0] = 0;
  if (!s || n == 0) {
    return;
  }
  CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

static void trim(char *s) {
  char *start = s;
  while (*start == ' ' || *start == '\t') {
    start++;
  }
  if (start != s) {
    memmove(s, start, strlen(start) + 1);
  }
  size_t n = strlen(s);
  while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\n')) {
    s[--n] = 0;
  }
}

static int ends_with(const char *s, const char *suffix) {
  size_t n = strlen(s);
  size_t m = strlen(suffix);
  return n >= m && strcmp(s + n - m, suffix) == 0;
}

static mach_port_t iokit_port(void) {
#ifdef kIOMainPortDefault
  return kIOMainPortDefault;
#else
  return kIOMasterPortDefault;
#endif
}

static int smc_call(const SMCKeyData *in, SMCKeyData *out) {
  size_t out_size = sizeof(SMCKeyData);
  kern_return_t kr = IOConnectCallStructMethod(
      g_smc, 2, in, sizeof(SMCKeyData), out, &out_size);
  return kr == KERN_SUCCESS && out->result == 0;
}

static uint32_t fourcc(const char *s) {
  return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
         ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

static int smc_open(void) {
  io_iterator_t it = 0;
  kern_return_t kr =
      IOServiceGetMatchingServices(iokit_port(), IOServiceMatching("AppleSMC"), &it);
  if (kr != KERN_SUCCESS) {
    return 0;
  }

  io_object_t preferred = 0;
  io_object_t fallback = 0;
  io_object_t dev;
  while ((dev = IOIteratorNext(it))) {
    io_name_t name;
    IORegistryEntryGetName(dev, name);
    if (strcmp(name, "AppleSMCKeysEndpoint") == 0) {
      if (preferred) {
        IOObjectRelease(preferred);
      }
      preferred = dev;
    } else {
      if (!fallback) {
        fallback = dev;
      } else {
        IOObjectRelease(dev);
      }
    }
  }
  IOObjectRelease(it);

  io_object_t target = preferred ? preferred : fallback;
  if (preferred && fallback) {
    IOObjectRelease(fallback);
  }
  if (!target) {
    return 0;
  }

  kern_return_t opened = IOServiceOpen(target, mach_task_self(), 0, &g_smc);
  IOObjectRelease(target);
  if (opened != KERN_SUCCESS) {
    return 0;
  }

  SMCKeyData in = {0};
  SMCKeyData out = {0};
  in.key = fourcc("PSTR");
  in.data8 = 9;
  if (!smc_call(&in, &out) || out.key_info.data_size != 4) {
    return 0;
  }
  g_pstr_info = out.key_info;
  g_pstr_ok = 1;
  return 1;
}

static int smc_read_pstr(double *watts) {
  if (!g_pstr_ok) {
    return 0;
  }
  SMCKeyData in = {0};
  SMCKeyData out = {0};
  in.key = fourcc("PSTR");
  in.key_info = g_pstr_info;
  in.data8 = 5;
  if (!smc_call(&in, &out)) {
    return 0;
  }
  float val;
  memcpy(&val, out.bytes, sizeof(val));
  if (!isfinite(val) || val < 0.0f || val > 400.0f) {
    return 0;
  }
  *watts = (double)val;
  return 1;
}

static int energy_channel(const char *group, const char *channel) {
  if (strcmp(group, "Energy Model") != 0) {
    return 0;
  }
  if (strcmp(channel, "GPU Energy") == 0) {
    return 1;
  }
  if (ends_with(channel, "CPU Energy")) {
    return 1;
  }
  if (strncmp(channel, "ANE", 3) == 0) {
    return 1;
  }
  if (strncmp(channel, "DRAM", 4) == 0) {
    return 1;
  }
  if (strncmp(channel, "GPU SRAM", 8) == 0) {
    return 1;
  }
  return 0;
}

static int ior_open(void) {
  CFDictionaryRef all = IOReportCopyAllChannels(0, 0);
  if (!all) {
    return 0;
  }

  CFArrayRef src = CFDictionaryGetValue(all, CFSTR("IOReportChannels"));
  if (!src || CFGetTypeID(src) != CFArrayGetTypeID()) {
    CFRelease(all);
    return 0;
  }

  CFIndex count = CFArrayGetCount(src);
  CFMutableArrayRef selected =
      CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
  for (CFIndex i = 0; i < count; i++) {
    CFDictionaryRef item = (CFDictionaryRef)CFArrayGetValueAtIndex(src, i);
    char group[128];
    char channel[128];
    cfstr_copy(IOReportChannelGetGroup(item), group, sizeof(group));
    cfstr_copy(IOReportChannelGetChannelName(item), channel, sizeof(channel));
    if (energy_channel(group, channel)) {
      CFArrayAppendValue(selected, item);
    }
  }

  if (CFArrayGetCount(selected) == 0) {
    CFRelease(selected);
    CFRelease(all);
    return 0;
  }

  g_chans = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, all);
  CFDictionarySetValue(g_chans, CFSTR("IOReportChannels"), selected);
  CFRelease(selected);
  CFRelease(all);

  CFMutableDictionaryRef unused = NULL;
  g_subs = IOReportCreateSubscription(NULL, g_chans, &unused, 0, NULL);
  if (unused) {
    CFRelease(unused);
  }
  if (!g_subs) {
    return 0;
  }
  return 1;
}

static double watts_from_energy(int64_t val, const char *unit, double seconds) {
  if (seconds < 1e-3) {
    seconds = 1e-3;
  }
  double per_sec = (double)val / seconds;
  if (strcmp(unit, "mJ") == 0) {
    return per_sec / 1e3;
  }
  if (strcmp(unit, "uJ") == 0) {
    return per_sec / 1e6;
  }
  if (strcmp(unit, "nJ") == 0) {
    return per_sec / 1e9;
  }
  return 0.0;
}

static int classify_channel(const char *channel) {
  if (strcmp(channel, "GPU Energy") == 0) {
    return 1;
  }
  if (ends_with(channel, "CPU Energy")) {
    return 0;
  }
  if (strncmp(channel, "ANE", 3) == 0) {
    return 2;
  }
  return -1;
}

static void parse_delta(CFDictionaryRef delta, double seconds, double *cpu, double *gpu, double *ane) {
  *cpu = *gpu = *ane = 0.0;
  if (!delta) {
    return;
  }
  CFArrayRef items = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
  if (!items || CFGetTypeID(items) != CFArrayGetTypeID()) {
    return;
  }
  CFIndex count = CFArrayGetCount(items);
  for (CFIndex i = 0; i < count; i++) {
    CFDictionaryRef item = (CFDictionaryRef)CFArrayGetValueAtIndex(items, i);
    char group[128];
    char channel[128];
    char unit[32];
    cfstr_copy(IOReportChannelGetGroup(item), group, sizeof(group));
    cfstr_copy(IOReportChannelGetChannelName(item), channel, sizeof(channel));
    cfstr_copy(IOReportChannelGetUnitLabel(item), unit, sizeof(unit));
    trim(unit);
    int kind = classify_channel(channel);
    if (kind < 0) {
      continue;
    }
    int64_t raw = IOReportSimpleGetIntegerValue(item, 0);
    double w = watts_from_energy(raw, unit, seconds);
    if (kind == 0) {
      *cpu += w;
    } else if (kind == 1) {
      *gpu += w;
    } else {
      *ane += w;
    }
  }
}

static void emit(void) {
  double cpu = 0, gpu = 0, ane = 0, pstr = 0;
  int have_energy = 0;

  if (g_subs && g_chans) {
    if (!g_prev) {
      g_prev = IOReportCreateSamples(g_subs, g_chans, NULL);
      g_prev_ns = monotonic_ns();
    }
    uint64_t now = monotonic_ns();
    int64_t wait_ns = (int64_t)50000000LL - (int64_t)(now - g_prev_ns);
    if (wait_ns > 0) {
      struct timespec ts = {.tv_sec = 0, .tv_nsec = (long)wait_ns};
      nanosleep(&ts, NULL);
    }
    CFDictionaryRef next = IOReportCreateSamples(g_subs, g_chans, NULL);
    uint64_t next_ns = monotonic_ns();
    if (g_prev && next) {
      CFDictionaryRef delta = IOReportCreateSamplesDelta(g_prev, next, NULL);
      double seconds = (double)(next_ns - g_prev_ns) / 1e9;
      parse_delta(delta, seconds, &cpu, &gpu, &ane);
      if (delta) {
        CFRelease(delta);
      }
      have_energy = 1;
    }
    if (g_prev) {
      CFRelease(g_prev);
    }
    g_prev = next;
    g_prev_ns = next_ns;
  }

  int have_pstr = smc_read_pstr(&pstr);
  double all = cpu + gpu + ane;
  double sys = have_pstr ? fmax(pstr, all) : all;
  int ok = have_energy || have_pstr;

  printf(
      "{\"ok\":%s,\"cpu\":%.3f,\"gpu\":%.3f,\"ane\":%.3f,\"all\":%.3f,\"sys\":%.3f}\n",
      ok ? "true" : "false", cpu, gpu, ane, all, sys);
  fflush(stdout);
}

int main(void) {
  int ior = ior_open();
  int smc = smc_open();
  if (!ior && !smc) {
    fprintf(stderr, "delta_watts: no IOReport energy counters or SMC PSTR\n");
    return 1;
  }

  char line[32];
  while (fgets(line, sizeof(line), stdin)) {
    emit();
  }
  return 0;
}

#pragma clang diagnostic pop
