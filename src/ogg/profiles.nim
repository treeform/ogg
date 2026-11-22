## Enable Fluffy trace points with -d:oggFluffy.
when defined(oggFluffy):
  import std/macros
  from fluffy/measure import measurePush, measurePop

  proc beginMeasure(name: string) {.raises: [].} =
    ## A missing interned trace name indicates a profiler invariant failure.
    try: measurePush(name)
    except KeyError as error: raise newException(Defect, error.msg)

  macro measure*(fn: untyped): untyped =
    ## Preserves decoder error effects while tracing procedure entry and exit.
    let name = newLit(fn[0].repr)
    fn[6].insert(0, quote do:
      beginMeasure(`name`)
      defer: measurePop())
    fn
else:
  template measure*(fn: untyped): untyped = fn
