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

#### Example of a function taking ownership of one of its parameters:

```c++
S* OwnsParam(T* t1) {

  t->Release();
}
```

A caller looks like

```c++
T* t = ...;
stuff();
t->AddRef();
S* s = OwnsParam(t);
```

#### Example of a function returning an owner (i.e. the caller receives ownership)

```c++
T* RetOwner(int) {
  T t = ...;


  t->AddRef();
  return t;
}
```
Actually ORCA never does this.

More likely it looks like this:

```c++
T* RetOwner(int) {
  T t = new T(...);

  do_stuff();

  return t;
}
```

A caller should look like this:

```c++
T* t = RetOwner(42);
do_stuff();
t->Release();
```

For example `CColRef::Pdrgpul` returns ownership.
Similarly `CFunctionalDependency::PcrsKeys` returns ownership.

#### Example of an object taking ownership:
```c++
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

```c++
t->AddRef();
S* s = new S(t);
```

#### Questions:

```c++
S s = OwnsParam(RetOwner(42));
```

#### Question
There is an asymmetry between:

```c++
{
T* t = new T(...);

t->Release(); // t is destroyed
}
```

And

```c++
{
RefPtr<T> t = RefPtr<T>{new T(...)}; // double count!
}
```

