# Modern Luau — What Changed, and What Models Get Wrong

**Current as of:** August 2026 (upstream Luau ~0.730, released 17 Jul 2026)
**Purpose:** context primer for anyone — human or LLM — whose mental model of Luau is a few years stale.

## How to read the confidence markers

Upstream Luau (the open-source language) and Roblox's deployed Luau are **not the same thing**. Roblox lags upstream, and some syntax is gated behind Studio betas or workspace properties even after it lands upstream.

- **[live]** — shipped and usable in Roblox today, high confidence
- **[upstream]** — in open-source Luau; verify before relying on it inside Roblox
- **[coming]** — RFC accepted, implementation partial or in progress

---

## 1. The type system was rewritten

### New Type Solver [live]

The New Type Solver left Studio Beta and went to **General Release in November 2025**, together with **non-strict-by-default**. There are now Scripting workspace properties to enable/disable the new solver and to set the default typechecking mode for scripts.

Practical consequences:

- Inference is much stronger. You need fewer annotations, and `--!strict` is far less painful than it was in 2023.
- Type *refinements* (narrowing via `if x then`, `type(x) == "number"`, etc.) actually work across control flow now.
- Error messages changed. Old advice about "just cast it with `:: any`" is mostly obsolete.
- `luau-analyze` takes `--solver=new` or `--solver=old`; **new is the default**.

### Type functions [live]

Types are now computed, not just declared. Built-in type functions include `keyof<T>`, `rawkeyof<T>`, `index<T, K>`, `rawget<T, K>`, `setmetatable<T, M>`, `getmetatable<T>`.

This changed the idiomatic OOP pattern significantly (see §6).

**User-defined type functions** also exist — you write a `type function` that runs at analysis time and manipulates types as values.

### Read/write property variance [live/upstream]

```luau
type T = {
    read name: string,   -- can't be assigned through this type
    write count: number, -- can't be read through this type
}
```

Read-only **indexers** landed in 0.721 [upstream]:

```luau
function printThem(a: {read Instance}) ... end
```

This matters because `{Player}` is not a subtype of `{Instance}` (the callee could insert a non-Player), but `{Player}` *is* acceptable where `{read Instance}` is expected. If you've ever been confused why passing an array to a function errored, this is the fix.

### `type:issubtypeof` [upstream]

Implemented in 0.724. Lets user-defined type functions ask subtyping questions directly.

---

## 2. New syntax you may not know exists

### `const` [live]

```luau
const MAX = 100
MAX = 200 -- error: cannot reassign a const binding
```

Key semantics, which people get wrong:

- It makes the **binding** immutable, not the value. `const t = {}` still allows `t.x = 1`. Pair with `table.freeze` for real immutability.
- Must be initialized at declaration. `const x` alone is an error.
- Shadowing in an inner scope is allowed.
- It's a **contextual keyword**, valid anywhere `local` is valid.
- It exists partly to enable constant folding and inlining — the compiler can exploit a guarantee that a symbol never rebinds.

The modern Roblox OOP idiom (§6) uses `const` in place of `local` for module-level tables.

### `export` for values [upstream]

Beyond the long-standing `export type`, there's now export-by-value semantics (RFC 179, implemented 0.723): a module with exports returns a **frozen table**, and all exported bindings are `const` by default.

```luau
export foo = 5
export function increment() ... end
```

Verify availability in Roblox before using — `export type` is definitely live; `export <value>` I would treat as not-yet-confirmed there.

### Function attributes [upstream, partially live]

```luau
@native
local function hotLoop() ... end

@[deprecated {
    use = "newThing",
    reason = "oldThing allocates per call",
}]
local function oldThing() ... end
```

- `@native` — per-function native codegen, finer-grained than the `--!native` chunk directive.
- `@deprecated` — the linter warns at call sites; LSPs strike it out in autocomplete. Takes optional named string params `use` and `reason`. Applies to named functions/methods and to table/class properties, and does **not** apply recursively to inner functions.
- Attribute params must be literals; attributes can't repeat on one declaration.

There is a `RedundantNativeAttribute` lint for `@native` on things that don't benefit.

### `declare extern type` replaces `declare class` [upstream]

If you write definition files (`.d.luau`) for luau-lsp, `declare class` is **being removed**. 0.727 already disallows `extern class` declaration syntax. Migrate to:

```luau
declare extern type Foo with
    bar: string
end
```

### Yielding iterators [upstream, 0.722]

You can now yield from inside a generator function driven by a `for ... in` loop:

```luau
for request in someIoGenerator() do ... end
```

Caveat: yielding in **metamethods is still unsupported**, including `__iter`.

### Classes [coming]

A classes RFC is accepted, with first implementation steps in 0.721. It introduces contextual keywords `class` and `public` (`private` later) plus two new top types, `object` and `class`. Class objects are always const and frozen. **Implementation inheritance is explicitly not committed to** — the team cites the fragile base class problem and method-inlining complexity. Generic classes get a separate future RFC.

Do not write code against this yet. Do know it's coming, because it will eventually make the `setmetatable<>` idiom legacy.

---

## 3. New standard library surface

### `vector` library [live]

The `vector` type existed before, but construction and methods had to be supplied by the embedder. There's now a real built-in `vector` library, which means fast-call optimization, vector constants embedded in bytecode, constant folding, and native lowering — `vector.dot` lowers to a CPU dot-product instruction; `vector.lerp` and `math.lerp` use fused-multiply-add.

Note this is Luau's `vector`, distinct from Roblox's `Vector3` datatype.

### `math` additions [live]

- `math.map(x, inMin, inMax, outMin, outMax)`
- `math.lerp(a, b, t)`
- `math.isnan(x)`, `math.isinf(x)`, `math.isfinite(x)`

If you've been hand-rolling `lerp` and `map` in a utils module, stop.

### `buffer` bit access [live]

`buffer.readbits(b, bitOffset, bitCount)` / `buffer.writebits(...)`. `bitCount` is in `[0, 32]`; `bitOffset` is not limited to 32-bit because buffers can reach 1 GB. Out-of-bounds throws.

Relevant if you're packing wire formats — this replaces manual shift-and-mask over `buffer.readu8`.

### `bit32.byteswap` [upstream]

One call instead of the seven-call shift/OR dance for endianness swapping.

### 64-bit `integer` type and library [upstream]

A genuine 64-bit integer value type with an `i` literal suffix (`123i`, `0b1000i`; note `-123i` parses but `-(123i)` does not) and a new `integer` library: `integer.idiv`, `.mod`, `.udiv`, `.urem`, `.min`, `.max`, conversion from `number` returning `nil` when not exactly representable, etc.

Important: **there are no arithmetic operators for integers**, and mixed `number`/`integer` operations are not supported. Native codegen for `*mod`/`*div`/`*rem` had a data-corruption bug fixed in 0.728, which tells you it's genuinely wired into NCG.

### Require by string [upstream]

The require-by-string RFC produced a separate `Luau.Require` library any embedder can include: alias resolution, `.luaurc` configuration, real and virtual filesystems. Roblox itself still uses `require(instance)`; this matters mostly for Lune/standalone Luau and for tooling.

---

## 4. Performance: what actually got faster

You mostly don't need to change code for these, but they change what "optimized Luau" looks like.

- **Inlining got much smarter.** The cost model is now re-evaluated *per call site* with constant arguments taken into account, so a large function can collapse to a small one and become inlinable. It also propagates constant variables that aren't literal values — including inlining a function passed as an argument.
- **Constant folding** now covers `string.char`, `string.sub`, string concatenation, and string interpolation (including partially-constant expressions), plus all vector arithmetic.
- **Micro-optimization the compiler does for you:** `const * var` is rewritten to `var * const` when `var` is annotated as a number, saving one bytecode instruction. Type annotations on arguments have real runtime value, not just analysis value.
- **Branchless codegen** for `==`/`~=`, `and`/`or` (via `SELECT_IF_TRUTHY`), and `type(x) == "number"` / `typeof(x) == "string"` checks, which become tag checks or pointer comparisons.
- **Load-store propagation** for vectors, upvalues, buffers, and userdata — repeated field reads and temporary allocations get eliminated. Table accesses are on the roadmap, not done.
- **`pcall`/`xpcall` are now stackless** in yieldable contexts, so they don't consume C call depth.
- **A JIT bytecode-to-bytecode inliner** landed in 0.727 (opt-in via `--jit-inliner` in the CLI).
- Native codegen now runs on **Android** and has been tested in production.

Roblox-side, the relevant knobs remain `--!native` (or `@native` per function) and `--!optimize 2`.

---

## 5. Tooling notes

- The file extension is **`.luau`**, not `.lua`. GitHub Linguist recognizes it.
- **luau-lsp** (JohnnyMorganz) is the standard language server outside Studio; it's actively contributed to upstream. Pairs with Rojo for external-editor workflows.
- **`.luaurc`** configures language mode, lint toggles, globals, and aliases. There's an RFC for a Luau-syntax config format with a typed `LuauConfig` shape (`languagemode`, `lint`, `linterrors`, `typeerrors`, `globals`, `aliases`).
- Lint names worth knowing when tuning config: `DeprecatedApi`, `TableOperations`, `MisleadingAndOr`, `ComparisonPrecedence`, `RedundantNativeAttribute`, `UninitializedLocal`, `CommentDirective`.

---

## 6. The idiom shift in OOP

This is the single biggest thing a stale model gets wrong. The old `Impl`/`Proto` boilerplate is **archived**. Modern:

```luau
--!strict

type Props = {
    name: string,
    balance: number,
}

const Account = {}
Account.__index = Account

export type Account = setmetatable<Props, typeof(Account)>

function Account.new(name: string, balance: number): Account
    const self = setmetatable({}, Account)
    self.name = name
    self.balance = balance
    return self
end

function Account.withdraw(self: Account, debit: number): ()
    self.balance -= debit
end

function Account.deposit(self: Account, credit: number): ()
    self.balance += credit
end

return Account
```

Three things changed:

1. **`setmetatable<Props, typeof(Account)>`** as a type function replaces `typeof(setmetatable({} :: Proto, {} :: Impl))` and the hand-written `Impl` type.
2. **Explicit `self` with `.`** rather than implicit `self` with `:`. You still *call* it with `account:withdraw(5)`; you *define* it with `function Account.withdraw(self: Account, ...)`. This types much better.
3. **`const`** instead of `local` for the class table.

`()` as a return type means "returns nothing" — it's the real syntax, not a workaround.

---

## 7. Things a model trained before ~2025 will get wrong

Ordered roughly by how often it happens.

### Luau language

| Stale belief | Reality |
|---|---|
| "Luau typechecking is weak; annotate everything or use `any`" | New solver infers most of it; `--!strict` is practical |
| `local` is the only binding form | `const` exists |
| Only `export type`, no value exports | Export-by-value RFC implemented upstream |
| No way to mark a function deprecated | `@[deprecated {...}]` attribute |
| `--!native` is the only native control | `@native` per function |
| `declare class` for definition files | `declare extern type ... with ... end` |
| No `lerp`/`map` in stdlib | `math.lerp`, `math.map` exist |
| No bit-level buffer access | `buffer.readbits`/`writebits` |
| Can't yield inside a `for ... in` generator | You can (still not in metamethods) |
| Luau has no integers | 64-bit `integer` type + library upstream |
| `Impl`/`Proto` OOP boilerplate is best practice | Superseded by `setmetatable<>` |
| Luau will get real classes "never" | Accepted RFC, in progress |

### Roblox API (adjacent, equally common failures)

- **`wait`, `spawn`, `delay` are deprecated.** Use `task.wait`, `task.spawn`, `task.defer`, `task.delay`, `task.cancel`. `wait()` throttles and can return late; `task.wait()` is the engine-scheduled version.
- **`RunService.Stepped`/`Heartbeat`/`RenderStepped` have modern names**: `PreSimulation`, `PostSimulation`, `PreRender` (plus `PreAnimation`). The old names still work but are legacy.
- **`Instance.new("Part", parent)`** — the second argument is discouraged; it hurts performance and ordering. Set `.Parent` last.
- **`LoadLibrary` is gone.** `getfenv`/`setfenv` are deprecated and deoptimize the script.
- **`unpack` → `table.unpack`**, `table.getn` → `#`.
- **Parallel Luau** exists: `Actor` instances, `task.desynchronize()` / `task.synchronize()`, and `SharedTable` for cross-actor shared state. A model that has never heard of Actors will write everything serial.
- **Attributes** (`instance:GetAttribute` / `SetAttribute` / `GetAttributeChangedSignal`) and **CollectionService tags** (`instance:AddTag`, `:HasTag`, `CollectionService:GetTagged`) are the modern alternatives to `ValueObject` children and name-based lookup.
- **Open Cloud v2** is the current external API surface (`x-api-key` header, `/cloud/v2/...`), not the old legacy endpoints.
- **MemoryStoreService** — hash maps, sorted maps, queues — is the right tool for cross-server ephemeral state, not DataStores.

### Meta-failure

Models hallucinate Roblox APIs confidently, because the API surface is huge and the naming is guessable-looking. If a method name is plausible but you can't find it on `create.roblox.com/docs`, assume it doesn't exist. This is a much bigger practical problem than any missing language feature.

---

## 8. Verify-before-relying list

Items marked [upstream] above where Roblox availability is the open question:

- `export <value>` (export-by-value)
- 64-bit `integer` type and `integer` library
- `@deprecated` and attribute parameters
- read-only indexers `{read T}`
- yielding iterators
- `bit32.byteswap`

Quickest check: type it into a Studio script and see if the parser complains, or check the Luau version Studio reports against the upstream release that introduced it.

---

## Sources

- Luau Recap for 2025: Runtime — https://luau.org/news/2025-12-19-luau-recap-runtime-2025
- Luau releases 0.720–0.730 — https://github.com/luau-lang/luau/releases
- Luau RFCs — https://rfcs.luau.org/ (`const-keyword`, `syntax-classes`, `syntax-attributes-functions`, `syntax-attribute-functions-deprecated`, `type-long-integer`, `function-buffer-bits`, `vector-library`, `config-luauconfig`)
- New Type Solver general release — https://devforum.roblox.com/t/general-release-luau's-new-type-solver/4084991
- Luau standard library reference — https://luau.org/library/