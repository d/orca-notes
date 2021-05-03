---
title: RefCount Refactoring

slideOptions:
  spotlight:
    enabled: true
---

# RefCount Refactoring

slide: https://hackmd.io/@j-/rJ8v-AVAD#/

---


---

# Intrusive RefCount

```cpp
template <class Derived>
class CRefCount {
  long refs_{1};

 public:
  CRefCount(const CRefCount&) = delete;
  void AddRef() { ++refs_; }
  void Release() {
    if (--refs_ == 0) delete static_cast<Derived*>(this);
  }
};
```

----

## Derived

```cpp
class CBitSet : public CRefCount<CBitSet> {};
```

----

## Pros

1. Avoid the "split control block" pitfall of `shared_ptr`
1. Optimization for some particular workloads

----

## Cons:

1. Losing `const`. (Compared to the idiom of `shared_ptr<const T>`)
1. Losing `weak_ptr`. (Have to avoid circularity)


---

# Manual Reference Counting:

The explict calls to `AddRef` and `Release` at the right spot to manage object lifetime.

----

## Example 1

```cpp
COrderSpec *CPhysicalIndexOnlyScan::PosDerive(
    CMemoryPool *CExpressionHandle &) const override {
  m_pos->AddRef();
  return m_pos;
}
```

```cpp
CPhysicalIndexOnlyScan::~CPhysicalIndexOnlyScan() {
  m_pindexdesc->Release();
  m_pos->Release();
}
```


----

## Example 2

<!-- .slide: style="font-size: 36px;" -->

```cpp
pexprOuter->AddRef();
pexprInner->AddRef();
pexprPred->AddRef();
CExpression *pexprResult =
    new CExpression(new TJoin(), pexprOuter, pexprInner, pexprPred);

// add alternative to results
pxfres->Add(pexprResult);
```

----

## Pros

1. No magic, what you see is what you get
1. "Drive stick": allows for micro-optimization, pre- C++ 11

----

## Cons

1. Manual manipulation of reference count permeates the code base
1. Lifetime manipulation becomes part of the API
   * local variables
   * return value of functions
   * function parameters
   * constructor initializers
   * class data members
   * elements in a container / array
1. Extremely hard to reason about locally

----

## Cons (ex)

We want these

<!-- .slide: style="width: 109%;" -->
```cpp
vector<CBitset> bitsets_;
unordered_map<int, CExpression> plans_;
```

We get those

```cpp
CDynamicPtrArray<CBitSet, CleanupRelease> *bitsets_;
CHashMap<int, CExpression, CleanupDelete, CleanupRelease> *hm_;
```

---

# Vision

1. Smart pointer that provide ownership semantics
1. Express ownership in code
1. Automatically handle lifecycle
1. `std::move` for micro optimization


----

## Instead of

<!-- .slide: style="font-size: 85%;" -->
```cpp!
class U {
  CExpression* m_pexpr;
  void SetExpr(CGroup* pexpr) {
    if (m_pexpr) m_pexpr->Release();
    m_pexpr = pexpr;
  }

  U(CExpression* pexpr) : m_pexpr(pexpr) {}
  ~U() {
    if (m_pexpr) m_pexpr->Release();
  }
};
```

Client code

```cpp
U* bar(CExpression* pexpr) {
  pexpr->AddRef();
  return new U(pexpr);
}
void foo(U* u, CGroup* pgroup) {
  pgroup->AddRef();
  u->SetGroup(pgroup);
}
```


----

## Ideally...

Destructor is gone! `AddRef` is gone.

```cpp!
class U {
  Ref<CExpression> m_pexpr;
  void SetExpr(Ref<CGroup> pexpr) { m_pexpr = pexpr; }

  U(Ref<CExpression> pexpr) : m_pexpr(pexpr) {}
};
```

Client code

```cpp
Ref<U> bar(Ref<CExpression> pexpr) { return new U(pexpr); }
void foo(U* u, CGroup* pgroup) { u->SetGroup(pgroup); }
```



----

<!-- .slide: style="font-size: 85%;" -->
## Optimization

For the performance-minded...

```cpp!
class U {
  Ref<CExpression> m_pexpr;
  void SetExpr(Ref<CGroup> pexpr) { m_pexpr = std::move(pexpr); }

  U(Ref<CExpression> pexpr) : m_pexpr(std::move(pexpr)) {}
};
```

Client code

```cpp
Ref<U> bar(Ref<CExpression> pexpr) { return new U(std::move(pexpr)); }
void foo(U* u, CGroup* pgroup) { u->SetGroup(pgroup); }
```

---

# Road map

1. "Semantic marker" / annotation
1. local reasoning
1. One-shot conversion guided by annotations

----

## Annotation

Helper tags:
```cpp
template <class T>
using owner = T;
template <class T>
using pointer = T;
```

To apply annotation on:
```cpp
U* foo(int, U*);
```

We might get
```cpp
owner<U*> foo(int, pointer<U*>);
```

----

<!-- .slide: style="font-size: 36px;" -->
## Conversion

* We "just" need to get every one of the following (reference-counted) annotated
  * variable;
  * function return type;
  * function parameter;
  * class data member

----

* We can then perform a conversion of the annotated code:
  * substitute a raw pointer `T*` for `pointer<T*>`
  * substitute a smart pointer `Ref<T>` for `owner<T*>`
  * remove all `Release` and `AddRef` calls


---

## Before:

```cpp
struct U : CRefCount<U> {};

U *F();

U *foo(int i, bool b, U *param) {
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

## Annotate

```cpp
struct U : CRefCount<U> {};

U *F();

owner<U *> foo(int i, bool b, pointer<U *> param) {
  pointer<U *> u = F();
  if (i < 42) {
    u->AddRef();
    return u;
  }
  param->AddRef();
  return param;
}
```

----

## Convert

```cpp
struct U : CRefCount<U> {};
U *F();
Ref<U> foo(int i, bool b, U *param) {
  U *u = F();
  if (i < 42) {
    return u;
  }
  return param;
}
```

---

# Tooling

* link to LLVM / Clang for access to the AST (abstract syntax tree)
* simple rules for local reasoning (examples)
* generate edits to source file

----

## Example rule

* A field (data member) released in destructor is an owner.

When we match
```cpp
struct R {
  T* t;
  ~R() { t->Release(); }
};
```

We annotate
```cpp
struct R {
  owner<T*> t;
  ~R() { t->Release(); }
};
```

----

## Local reasoning

* We only need to look at code from one translation unit
* Often we only need to look at code around one variable, or within one function
* This is not only good for tooling, but it's also better for humans

----

## Bonus: propagation rule example

* Propagation rule: a rule that matches not only code pattern but existing annotation
* e.g. virtual functions share the same "ownership" signature (return type, parameter)

----

## Bonus example (Contd)

<!-- .slide: style="width: 110%" -->

<table>
<tr>
<td style="width: 50%">Before propagation</td>
<td>After One iteration of propagation</td>
</tr>
<tr>
<td>

```cpp!
struct Q {
  virtual U* foo();
  virtual U* bar();
};

struct R : Q {
  owner<U*> foo() override;
  pointer<U*> bar() override;
};
```

</td>
<td>

```cpp
struct Q {
  virtual owner<U*> foo();
  virtual pointer<U*> bar();
};

struct R : Q {
  owner<U*> foo() override;
  pointer<U*> bar() override;
};
```

</td>
</tr>
</table>

---

# Scale

In a half-a-million LOC code base, our tool changed around 35K lines of code.

```
 git diff --shortstat
 1682 files changed, 33104 insertions(+), 28274 deletions(-)
```

---

# Bonus

* How to identify `std::move` (CFG)
* Future work (DFA)

---

# Identifying `move` opportunities

* Observation: an owner can be moved on its definite last use
* Construct a control flow graph (CFG)
* Find last use in the basic block (BB) immediately before the exit block

<!-- .slide: style="font-size: 30px;" -->

Before

```cpp
bool F(gpos::owner<T*>);

bool bar(T* t) { return F(t); }
```

After

```cpp
bool F(gpos::owner<T*>);

bool bar(owner<T*> t) { return F(std::move(t)); }
```

---

# We can do better than CFG


<table style="margin: 0 -10% 0 -10%; width: 120%">
<tr>
<td>
Given
</td>
<td>
We want
</td>
</tr>
<tr>
<td>

```cpp
bool F(gpos::owner<T*>);

bool bar(T* t, int x) {
  if (F(t)) {
    return x < 42;
  } else {
    return x > 420;
  }
}
```

</td>
<td>

```cpp
bool F(gpos::owner<T*>);

bool bar(owner<T*> t, int x) {
  if (F(std::move(t))) {
    return x < 42;
  } else {
    return x > 420;
  }
}
```

</td>
</tr>
</table>

----

## Data Flow Analysis

* What if the definite last use occurs too early and there are branches after it? We lose an opportunity to move.

* We can taylor the CFG for each variable, contracting nodes that don't affect the usage of a variable, simplifying the graph

----


<table style="margin: 0 -10% 0 -10%; width: 120%">
<tr>
<td>
Given
</td>
<td>
CFG
</td>
</tr>
<tr>
<td>

```cpp
bool F(gpos::owner<T*>);

bool bar(T* t, int x) {
  if (F(t)) {
    return x < 42;
  } else {
    return x > 420;
  }
}
```

</td>
<td>

* B0 (EXIT) Preds: [1,2]

* B1 Succs: 0 Preds: 3

  1. `return x < 42`

* B2 Succs: 0 Preds: 3

  1. `return x > 420`

* B3 Succs: [1,2] Preds: 4

  1. F(t)
  1. Terminal: if (F(t))

* B4 (ENTRY) Succs: 3

</td>
</tr>
</table>
