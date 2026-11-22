## Runtime dispatch is compiled for the baseline architecture.
const useX86Simd* = defined(amd64) and not defined(oggNoSimd) and
  not defined(js) and (defined(gcc) or defined(clang) or defined(vcc))

when useX86Simd:
  when defined(vcc):
    proc cpuid(info: ptr int32, leaf, subleaf: int32)
        {.importc: "__cpuidex", header: "<intrin.h>".}
    proc xgetbv(index: uint32): uint64 {.importc: "_xgetbv", header: "<intrin.h>".}

    proc detectAvx2(): bool =
      ## Requires the AVX2 instruction set and OS support for XMM/YMM state.
      var info: array[4, int32]
      cpuid(addr info[0], 0, 0)
      if info[0] < 7: return false
      cpuid(addr info[0], 1, 0)
      const required = (1'i32 shl 27) or (1'i32 shl 28)
      if (info[2] and required) != required or (xgetbv(0) and 6) != 6:
        return false
      cpuid(addr info[0], 7, 0)
      (info[1] and (1'i32 shl 5)) != 0

    let hasAvx2* = detectAvx2()
  else:
    # GCC and Clang include the OS register-state check in this predicate.
    proc supports(feature: cstring): cint {.importc: "__builtin_cpu_supports", nodecl.}
    let hasAvx2* = supports(cstring"avx2") != 0
