# Smart Pointers for `CRefCount<T>`

## Terminology:

### Pointer
A _Pointer_ (capital P) denotes a piece of code
(a block scope, a function, an object)
that references another object through a pointer (or reference, "pointers" with a lowercase "p" hereafter),
but is never responsible for managing the lifetime of the pointee
(in plain English, they don't destroy the pointed-to objects).

Pointers assume that the pointers they hold don't dangle (the pointees always outlive them).

### Owners
An _Owner_ is a piece of code (a block scope, a function, an object) that is responsible for managing the lifetime of an object they reference through a pointer.

"Managing a pointee's lifetime" best manifests itself through through the owner calling `Release()`

### Values
A value refers to the "content" or meaning that occupies the address of an object. 42 is a value. The string `"hello world"` is a value.

## Examples

### Example of a function taking ownership of one of its parameters:

```C++
S* OwnsParam(T* t1) {

  t->Release();
}
```

A caller looks like

```C++
T* t = ...;
stuff();
t->AddRef();
S* s = OwnsParam(t);
```

### Example of a function returning an owner (i.e. the caller receives ownership)

```C++
T* RetOwner(int) {
  T t = ...;


  t->AddRef();
  return t;
}
```
We have 157 such `return` statements.

Or more likely it looks like this:

```C++
T* RetOwner(int) {
  T t = new T(...);

  do_stuff();

  return t;
}
```
We have 452 such return statements (only counting C++ files, not headers)

A caller should look like this:

```C++
T* t = RetOwner(42);
do_stuff();
t->Release();
```

For example `CColRef::Pdrgpul` returns ownership.
Similarly `CFunctionalDependency::PcrsKeys` returns ownership.

### Example of an object taking ownership:
```C++
struct S {
  T* t_;

  S(T* t) : t_(t) {}

  ~S() {
    if (t)
      t_->Release();
  }
}
```

A caller that constructs an object of type `S` should look like this

```C++
t->AddRef();
S* s = new S(t);
```

## Parking Lot Questions:

#### Question 1
```C++
S s = OwnsParam(RetOwner(42));
```

#### Question
There is an asymmetry between:

```C++
{
T* t = new T(...);

t->Release(); // t is destroyed
}
```

And

```C++
{
RefPtr<T> t = RefPtr<T>{new T(...)}; // double count!
}
```

## Migration strategy

### Annotating, no functional change (NFC)

Annotations:

```C++
template <T> // requires std::is_pointer_v<T>
using owner<T*> = T;

template <T> // requires std::is_pointer_v<T>
using pointer<T*> = T;
```

#### Base cases
These base cases only depends on the original AST, and can be done in one pass (OK maybe fixing up function declaration needs a second pass, but mostly).

##### base.varOwn
A local variable initialized to `new ...` is an owner. i.e. when we match:

```C++
T* t = new ...;
```

We annotate:

```C++
owner<T*> t = new ...;
```

##### base.varPtr
A local variable that is returned right after an `AddRef()` is a pointer.

##### base.paramOwn
A function parameter that has `->Release` called on it is an owner, i.e. when we match:

```C++
void OwnsParam(T* t, int ...) {
   t->Release();
}
```

We annotate (both definition and its declaration in header):

```C++
void OwnsParam(owner<T*> t, int ...)
```

##### base.retPtr
A function parameter that never has `Release` called on it is a pointer, i.e. we annotate it as

```C++
void PointsToParam(pointer<T*> t) {
}
```

##### base.memOwn
A non-static member variable of a struct (or class) that is released in its destructor is an owner. i.e. when we match:

```C++
struct S {
  T* t_;

  ~S() { SafeRelease(t_); } // or t_->Release()
};
```

We annotate:

```C++
struct S {
  owner<T*> t_;

  ~S() { SafeRelease(t_); } // or t_->Release()
};
```

#### Owner propagation
Once we write out the annotation done in the base cases, we can further propagate the annotation. We don't know how far we can get with one iteration, but the hope is that we converge pretty quickly. IDK, we'll need to try and find out.

##### prop.varOwn
A local variable initialized with a function returning an owner is an owner. i.e. when we match:

```C++
owner<T*> f();

T* t = f();
```
we annotate:

```C++
owner<T*> f();

owner<T*> t = f();
```

##### prop.retOwn
A function returning a local owner variable, or tail-calls a function returning an owner returns an owner. i.e. when we match

```C++
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

#### Call site cross-examination
Once the propagation converges to a stationary point, we should validate some of our assumptions.

##### val.ptrToOwn
A pointer (and an owner) variable (or param) should `AddRef()` before being passed as an argument to an owner parameter in a function call.

##### val.ownMove
A local owner variable being passed as an argument without an `AddRef()` is a move.

Question: how to identify the corresponding `AddRef()` of an owner argument construction?
This might be easy to do when an owner `t` is copied to an argument only once.
Idea: identify the possible "move" and annotate that. Once we annotate all moves, we might be able to say the number of `AddRef()` should be equal the number of argument passing.

##### val.ownLocalRet
A local owner variable should not `AddRef()` before being returned as an owner.

##### val.memRet
A member owner variable should `AddRef()` before being returned as an owner.

#### Conversion
Our vision would be to remove all the annotation once we have sufficient information, and the end result looks like:

1. A human needs to inspect each unannotated pointer, and either manually annotate it, or come up with new base rules or new propagation rules

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

1. each non-owning variable `pointer<T*> t` is replaced with a raw pointer
   1. Assumption: `t` doesn't do `Release()` for managing lifetime
   1. Assumption: All calls to `t->AddRef()` is passing a pointer to an owner argument at function call


