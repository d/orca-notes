---
title: RefCount Refactoring
---

# RefCount Refactoring

slide: https://hackmd.io/@j-/rJ8v-AVAD#/

---


---

### Before:

```cpp
    struct T : gpos::CRefCount<T> {};
    using U = T;
    struct S : T {};

    U *F();

    U *foo(int i, bool b, S *param) {
      U *u = F();
      if (i < 42) {
        u->AddRef();
        return u;
      }
      param->AddRef();
      return param;
    }

```

----

### After

```cpp
    struct T : gpos::CRefCount<T> {};
    using U = T;
    struct S : T {};

    U *F();

    U *foo(int i, bool b, gpos::pointer<S *> param) {
      gpos::pointer<U *> u = F();
      if (i < 42) {
        u->AddRef();
        return u;
      }
      param->AddRef();
      return param;
    }
```

---

### Before:

```cpp
    struct T : gpos::CRefCount<T> {};
    using U = T;
    struct S : T {};

    U *F();

    U *foo(int i, bool b, S *param) {
      U *u = F();
      if (i < 42) {
        u->AddRef();
        return u;
      }
      param->AddRef();
      return param;
    }

```

----

### After

```cpp
    struct T : gpos::CRefCount<T> {};
    using U = T;
    struct S : T {};

    U *F();

    Ref<U*> foo(int i, bool b, S * param) {
      U * u = F();
      if (i < 42) {
        return u;
      }
      return param;
    }
```


---

## What To Do Next

* Incorporate a-priori knowlege of our templated data structures
  1. e.g. We know `CDynamicPtrArray<T, CleanupRelease>::Append` takes an owner
* Output parameters: e.g. `CExpression**` => `owner<CExpression*>*`
