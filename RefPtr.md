# Smart Pointers for `CRefCount<T>`

# Terminology:

## Pointer
A _Pointer_ (capital P) denotes a piece of code
(a block scope, a function, an object)
that references another object through a pointer (or reference, "pointers" with a lowercase "p" hereafter),
but is never responsible for managing the lifetime of the pointee
(in plain English, they don't destroy the pointed-to objects).

Pointers assume that the pointers they hold don't dangle (the pointees always outlive them).

In some vocabulary this is also called an [observer](https://en.cppreference.com/w/cpp/experimental/observer_ptr).

## Owners
An _Owner_ is a piece of code (a block scope, a function, an object) that is responsible for managing the lifetime of an object they reference through a pointer.

"Managing a pointee's lifetime" best manifests itself through through the owner calling `Release()`

# Examples

## Example of a function taking ownership of one of its parameters:

```cpp
S* OwnsParam(T* t1) {

  t1->Release();
}
```

A caller looks like

```cpp
T* t = ...;
stuff();
t->AddRef();
S* s = OwnsParam(t);
```

We have 40 such parameters.
Some of those look unnecessary
-- as in, raw pointers without `AddRef()` suffice --
but we'll honor the intent during the migration, and only optimize them after the switch.

## Example of a function returning an owner (i.e. the caller receives ownership)

```cpp
T* RetOwner(int) {
  T t = ...;


  t->AddRef();
  return t;
}
```
We have 157 such `return` statements.

Or more likely it looks like this:

```cpp
T* RetOwner(int) {
  T *t = new T(...);

  do_stuff(t);

  return t;
}
```
We have 452 such return statements (only counting C++ files, not headers)

A caller should look like this:

```cpp
T* t = RetOwner(42);
do_stuff(t);
t->Release();
```

For example `CColRef::Pdrgpul` returns ownership.
Similarly `CFunctionalDependency::PcrsKeys` returns ownership.

## Example of an object owning a field:

```cpp
struct S {
  T* t_;

  S(T* t) : t_(t) {}

  ~S() {
    if (t_)
      t_->Release();
  }
}
```

We have 486 occurrences of `Release()` called on a field (non-static member variable) from destructors in ORCA.
Often enough, ORCA also does a variant

```patch
   ~S() {
-    if (t)
-      t_->Release();
+      SafeRelease(t_);
   }
```

We have 324 such occurrences of `SafeRelease` called on a field from destructors in ORCA `.cpp` files.

A caller that constructs an object of type `S` should look like this

```cpp
t->AddRef();
S* s = new S(t);
```

## Example of an object owning through a container

```cpp
struct S {
  gpos::CDynamicPtrArray<T, gpos::CleanupRelease> *many_t_;
};
```

Here an `S` owns a dynamic pointer array of `T`, but `many_t_` owns each element stored in it.

# Parking Lot Questions:

### Question 1
```cpp
S s = OwnsParam(RetOwner(42));
```

### Question
There is an asymmetry between:

```cpp
{
T* t = new T(...);

t->Release(); // t is destroyed
}
```

And

```cpp
{
RefPtr<T> t = RefPtr<T>{new T(...)}; // double count!
}
```

# Migration strategy
The following five parts are about migrating away from manual reference counting:

1. Annotating intent, no functional change (NFC)
   1. base cases
   1. propagating annotation
1. Human supervision: see what's not annotated, come up with new rules, iterate, or manual intervention.
1. Validating assumptions at call sites
1. Final conversion

# Annotating (NFC)

Annotations:

```cpp
template <T> // requires std::is_pointer_v<T>
using owner<T> = T;

template <T> // requires std::is_pointer_v<T>
using pointer<T> = T;
```

# Base cases
These base cases only depends on the original AST, and can be done in one pass (OK maybe fixing up function declaration needs a second pass, but mostly).

## base.varOwnNew
A local variable initialized to `new ...` is an owner. i.e. when we match:

```cpp
T* t = new ...;
```

We annotate:

```cpp
owner<T*> t = new ...;
```

We have 2288 such local variables.

Tally of variables initalized with new (excluding the ones that are released)

gpopt | gporca | total
---|---|---
249 | 1459 | 1708

## base.varOwnRelease
A local variable that has `Release` member function called on it is an owner. i.e. when we match:

```cpp
T *t = ...;

if (cond) {
  t->Release();
  foo();
} else { ... }
```

We annotate:

```cpp
owner<T*> t = ...;

if (cond) {
  t->Release();
  foo();
} else {}
```

We have 1541 occurrences of such local variables in ORCA `.cpp` files.

## base.varOwnSafeRelese
A local variable that has the static function `SafeRelease` called on it is an owner.

We have 72 such local variables in ORCA `.cpp` files.

Combined occurrences of local variables that are released:

gpopt | gporca | total
---|---|---
118 | 1615 | 1733

## base.varPtr
Questionable: A local variable that is returned right after an `AddRef()` is a pointer.
I don't remember what inspired this rule, and it takes a little more than clang-query to find those.

## base.parmOwn
A function parameter that has `Release` member function called on it is an owner, i.e. when we match:

```cpp
void OwnsParam(T* t, int ...) {
   t->Release();
}
```

We annotate (both definition and its declaration in header):

```cpp
void OwnsParam(owner<T*> t, int ...)
```

Hint: parameters that are unconditionally released are taking unnecessary ownership.
We can optimize them away in a second pass.
We have about 12 such superfluous owners. Maybe a pre-factoring to eliminate them?

gpopt | gporca | total
---|---|---
2|85|87

## base.parmPtr

**This is wrong**

~~A function parameter that never has `Release` called on it is a pointer~~, i.e. we annotate it as

```cpp
void PointsToParam(pointer<T*> t) {
}
```

## base.retOwnNew

A function whose return value is a "new" expression returns ownership. i.e. when we match:

```cpp
T* foo() {
  return new T;
}
```

we annotate

```cpp
owner<T*> foo() {
  return new T;
}
```

gpopt | gporca | total
---|---|---
38 | 682 | 720

## base.retPtr
This one is a little ORCA-specific: a function returning a parameter returns a pointer. i.e. when we match:

```cpp
T *foo(T *parm1, U parm2) {
  return parm1;
}
```

we annotate

```cpp
pointer<T*> foo(T *parm1, U parm2) {
  return parm1;
}
```

We have 242 occurrences of functions returning a parameter in ORCA `.cpp` files (and a lot more in headers).

## base.fieldOwnSafeRelease
A field (data member) of a struct (or class) that is released in its destructor is an owner. i.e. when we match:

```cpp
struct S {
  T* t_;

  ~S() { SafeRelease(t_); } // or t_->Release()
};
```

We annotate:

```cpp
struct S {
  owner<T*> t_;

  ~S() { SafeRelease(t_); } // or t_->Release()
};
```

We have 324 (`SafeRelease`d, or 486 for `Release`) such fields in ORCA `.cpp` files.

|   | gpopt | gporca | total
---|---|---|---
Release | 11 | 537 | 548
SafeRelease | 2 | 344 | 346
total | 13 | 881 | 894

## base.fieldPtr
A field that is never released in the destructor of its class is a pointer. i.e. when we match:

```cpp
struct S {
  T* t_;
  const T* ct_;

  ~S() { // no releasing of t_ nor ct_ }
};
```

We annotate:

```cpp
struct S {
  pointer<T*> t_;
  pointer<const T*> ct_;

  ~S() { // no releasing of t_ nor ct_ }
};
```

gpopt | gporca | total
---|---|---
7 | 165 | 172

# Owner propagation
Once we write out the annotation done in the base cases, we can further propagate the annotation.
We don't know how far we can get with one iteration (because the derivation is iterative / recursive),
but the hope is that we converge to a stationary point pretty quickly.
IDK, we'll need to try and find out.

## prop.varOwn
A local variable initialized with a function returning an owner is an owner. i.e. when we match:

```cpp
owner<T*> f();

T* t = f();
```
we annotate:

```cpp
owner<T*> f();

owner<T*> t = f();
```

## prop.retOwn
A function returning a local owner variable, or tail-calls a function returning an owner returns an owner. i.e. when we match

```cpp
owner<T*> f();

T* g() {
  owner<T*> t = ...;

  return t; // not just variable, this can be any expression with an owner type
  // return f();
}
```
We annotate:

```
owner<T*> g();
```

I hesitated to generalize the above rule as "a function returning an owner expression, well, returns an owner" because I wasn't sure about parameters. Fortunately ORCA never returns a parameter that has been `Release()`d.

# Call site cross-examination
Once the propagation converges to a stationary point, we should validate some of our assumptions.

## val.ptrToOwn
A pointer (and an owner) variable (or param) should `AddRef()` before being passed as an argument to an owner parameter in a function call.

## val.ownMove
A local owner variable being passed as an argument without an `AddRef()` is a move.

Question: how to identify the corresponding `AddRef()` of an owner argument construction?
This might be easy to do when an owner `t` is copied to an argument only once.
Idea: identify the possible "move" and annotate that. Once we annotate all moves, we might be able to say the number of `AddRef()` should be equal the number of argument passing.

## val.ownLocalRet
A local owner variable should not `AddRef()` before being returned as an owner.

## val.fieldRet
An owner field should `AddRef()` before being returned as an owner.

# Conversion
Once every pointer becomes annotated as either `Pointer<T*>` or `Owner<T*>`, we'll have sufficient information about the intent.
We can then convert the code mechanically:

1. A human needs to inspect each unannotated pointer, and either manually annotate it, or come up with new base rules or new propagation rules

1. each non-owning variable `pointer<T*> t` is replaced with a raw pointer
   1. Assumption: `t` doesn't do `Release()` for managing lifetime
   1. Assumption: All calls to `t->AddRef()` is passing a pointer to an owner argument at function call

1. each owner variable `owner<T*> t` is replaced with a (hypothetically named) smart pointer `RefPtr<T> t`
   1. All references of `t->Release()` should be removed: this happens automatically when `t`
      1. goes out of function / block scope, or
      1. when the owning object destructs.
   1. All references of `t->AddRef()` should be removed: this happens automatically when we
      1. pass (copy) `t` into a function argument, or
      1. return (copy) `t` from a function returning `RefPtr<T>`
      1. Observation: currently we have a lot of `getter` functions that effectively _should_ return an owner, but they instead push the `AddRef` to their callers. Validate this assumption, and we might be able to clean it up before / after conversion.
   1. Open questions: come up with rules that identify `std::move(t)` when we pass `t` to another owner.
      Obviously this has to be the last time we copy it (_use_ it actually: use-after-move is UB)

1. (TBD) special care is needed to convert various owning containers (e.g. `gpos::CDynamicPtrArray<T, gpos::CleanupRelease>`) so that:
   1. The elements stored are of type `RefPtr<T>`
   1. The container no longer manages the lifetype of the pointee any more than normal `construct` / `destroy` the `RefPtr` objects (not pointers)


# Observation on container touch poins

## `CDynamicPtrArray`

### Only used when `CleanupFn == gpos::CleanupNULL`:

1. `AppendArray`

1. `IndexOf`

1. `IndexesOfSubsequence`

1. `CreateReducedArray`

### Not used with `CleanupRelease`

1. `Find`

# Frequently Given Answers (FAQ)

## Weak Pointers?
We theoretically cannot have a weak pointer in the current code base, but!
Shreedhar raises the question of the "three-body problem": do we have code that does this:
1. `A` has a owning (raw) pointer to object `B`
1. `B` has a owning (raw) pointer to object `A`
1. But we always use a third entity to "nuke them both out of orbit".
So this just sounds like extremely brittle and bad code that violates all sorts of principles...

## Implementation of `RefPtr`
Here's a sketch:

```cpp
template <class T>
struct RefPtr {
  RefPtr() = default;
  ~RefPtr() { if (p_) p_->Release(); }

  RefPtr(T *p): p_(p) { if (p_) p_->AddRef(); }
  RefPtr(RefPtr &&other) : p_(other.p_) { other.p_ = nullptr; }
  RefPtr(const RefPtr &other): RefPtr(other.p_) {}

  void swap(RefPtr& other) { std::swap(p_, other.p_); }
  // copy and move assignment
  RefPtr &operator=(RefPtr sink) { swap(sink); return *this; }

  T *get() const { return p_; }
  explicit operator bool() const { return p_; }
  T *operator->() const { return p_; }

private:
  T* p_ = nullptr;
};

// helper analogous to std::allocate_shared
// use this to mitigate problems in the following pattern:
// T* t = GPOS_NEW(mp) T(mp, GPOS_NEW(mp) R(mp, ...), GPOS_NEW(mp) S(mp, ...))
// do this instead:
// RefPtr<T> t = allocate_ref<T>(mp, allocate_ref<R>(...), allocate_ref<S>(...))
// Reference: GotW #56, GotW #102

template <class T, class MP, class Args...>
RefPtr<T> allocate_ref(MP mp, Args&&... args) { return {GPOS_NEW(mp) T(args...);} }
```

Note in the sketch above:
1. `RefPtr<T>` is implicitly convertible from `T*`.
1. `RefPtr<T>` is not implicitly convertible to a `T*`.

The first choice is negotiable, given that we can work on the tooling for conversion.

See [Chapter 7.7][implicit-conversion-to-raw-poiner-types] from Alexandrescu's
Modern C++ Design and [Herb Sutter's Reader Q&A][why-dont-smart-pointers] for a
discussion of why we often should be judicious in enabling implicit conversion
to raw pointers from smart poiners.

See GotW #102 and GotW #56 for the reason why we want to avoid the pattern of
naked new expressions and use a helper like `gpos::allocate_ref` suggested at
the bottom of the sketch

[implicit-conversion-to-raw-poiner-types]: https://www.informit.com/articles/article.aspx?p=31529&seqNum=7
[why-dont-smart-pointers]: https://herbsutter.com/2012/06/21/reader-qa-why-dont-modern-smart-pointers-implicitly-convert-to/

## Circular dependency?
Q: the above sketch seems to suggest that you need to provide a complete type `T` to `RefPtr<T>`.
Can we handle the situation when `T` is forward declared,
i.e. the declaration of `T::AddRef` isn't available to the template instantiation?

A: Yes. I'm not 100% sure we have to handle that yet, but yes we can definitely deal with it.
The trick will be to introduce one more abstraction around `AddRef` and `Release`.

TODO: fill in the sketch when we actually have this situation.

## Why do functions need to return a RefPtr at all if a caller can just decide to take ownership?
Q: Shouldn't all functions just return raw pointers, because callers can do the following?

```cpp
T *Func1();

void Func2() {
   RefPtr<T> t_ = Func1();
}
```

No.

Because it's often unsafe to allow the caller to discard the return value ("drop it on the floor"), shortest example:

```cpp
T* Func1() {
  auto t = new T(arg1, arg2);
  return t;
}
```

Here the caller is forced to take ownership, otherwise it leaks. Compare to the safe version:

```cpp
RefPtr<T> Func1() {
  auto t = gpos::allocate_ref<T>(arg1, arg2);
  return t;
}
```

Here the function transfers ownership to the caller. And if the temporary `RefPtr<T>` gets dropped on the floor, it destroys the object correctly, no leak.
