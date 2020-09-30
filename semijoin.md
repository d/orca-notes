# Reordering Semijoins

# Notations
## Semijoin
```sql
SELECT *
FROM R
WHERE EXISTS (SELECT * FROM S WHERE p(R, S));
```

$$
R \ltimes_{p(r,s)} S = R \ltimes (\sigma_{p(r,s)} S)
$$

## Antijoin
```sql
SELECT *
FROM R
WHERE NOT EXISTS (SELECT * FROM S WHERE p(R, S));
```

$$
R \bar\ltimes_{p(r,s)} S = R \bar\ltimes (\sigma_{p(r,s)} S)
$$

# A Semijoin Is Movable Around An Inner Join
Think about associativity, except this involves two operations:

Generally, if you have an inner join after a semijoin, you can reorder them, i.e. 

$$
R \Join_{p(r,s)} ( S \ltimes_{q(r,s,t)} T )=
( R \Join_{p(r,s)} S ) \ltimes_{q(r,s,t)} T
$$

<details><summary>Proof</summary>

1. Let $(r,s) \in LHS$
1. $\iff p(r,s)$ and $\exists t \in T$ such that $q(r,s,t)$
1. $\iff (r,s) \in RHS$

</details>

Similarly, one can move ("defer") an antijoin to after an adjacent inner join:

# Antijoin Is Movable Around An Inner Join

$$
R \Join_{p(r,s)} ( S \bar\ltimes_{q(r,s,t)} T )=
( R \Join_{p(r,s)} S ) \bar\ltimes_{q(r,s,t)} T
$$

<details><summary>Proof</summary>

1. Let $(r,s) \in LHS$
1. $\iff p(r,s)$ and $\forall t \in T$ such that $\neg q(r,s,t)$
1. $\iff (r,s) \in RHS$

</details>

# Semijoin Is Kind Of Commutative

Definitely not saying $R \ltimes_p S$ is in any way equivalent to $S \ltimes_p R$.

Instead of thinking about a binary operation, think of $\ltimes_p S$ as a "filter", or "restriction" on $R$. Multiple such "restriction" operations are, in fact, commutative:

$$
( R \ltimes_{p(r,s)} S ) \ltimes_{q(r,t)} T =
( R \ltimes_{q(r,t)} T ) \ltimes_{p(r,s)} S =
R \ltimes_{q \land p} ( S \times T )
$$

Mnemonic:
1. $R$ is first restricted by $S$ over predicate $p$, then restricted by $T$ over predicate $q$
1. $R$ is first restricted by $T$ over predicate $q$, then restricted by $S$ over predicate $p$
1. $R$ is restricted by $T \times S$ over predicate $p \land q$

Similarly, we can have two more general rules:

# Antijoin Is Kind of Commutative

$$
( R \bar\ltimes_{p(r,s)} S ) \bar\ltimes_{q(r,t)} T=
( R \bar\ltimes_{q(r,t)} T ) \bar\ltimes_{p(r,s)} S =
R \bar\ltimes_{q \land p} ( S \times T )
$$

# Antijoins And Semijoins Are Kind Of Commutative

$$
( R \ltimes_{p(r,s)} S ) \bar\ltimes_{q(r,t)} T=
( R \bar\ltimes_{q(r,t)} T ) \ltimes_{p(r,s)} S
$$

# Lateral (Correlated) Semijoins

Generally, lateral semijoins are immovable

If we attempt to reorder

$$
R \ltimes_{p(r,s)} (S \ltimes_{q(r,s,t)} T)
$$

into

$$
(R \ltimes_{p(r,s)} S) \ltimes_{q(r,s,t)} T
$$

it doesn't even make sense because the predicate $q(r,s,t)$ has dangling arguments!

## Degenerate Antijoins and Semijoins:
In SQL:

```sql
SELECT y
FROM T
WHERE NOT EXISTS (
  SELECT 1 FROM U
);
```

In Relational Algebra symbols:

$$
T \bar\ltimes U
$$

This is degenerate because the outcome doesn't quite "anti-join" (or "restrict" in Codd's terms) $T$:

$$
T \bar\ltimes U =
\begin{cases}
T & \text{if } U = \emptyset\\
\emptyset & \text{otherwise}
\end{cases}
$$

Degenerate semijoins are similar:

$$
T \ltimes U =
\begin{cases}
T & \text{if } U \neq \emptyset\\
\emptyset & \text{otherwise}
\end{cases}
$$

## Inner Joins and Semijoins

An inner join after a degenerate semijoin can be reordered to be joined before:

$$
R \Join_{p(r,t)} ( T \ltimes_{q(r,u)} U ) =
( R \Join_{p(r,t)} T ) \ltimes_{q(r,u)} U
$$

And the simpler case
$$
R \Join_{p(r,t)} ( T \ltimes_{q(r,t)} U ) =
( R \Join_{p(r,t) \land q(r,t)} T ) \ltimes U
$$

## Inner Joins and Antijoins

An inner join after a degenerate antijoin can be reordered to be joined before:

$$
R \Join_{p(r,t)} ( T \bar\ltimes_{q(r,u)} U ) =
( R \Join_{p(r,t)} T ) \bar\ltimes_{q(r,u)} U
$$

and the simpler case
$$
R \Join_{p(r,t)} ( T \bar\ltimes_{q(r,t)} U ) =
( R \Join_{p(r,t) \land q(r,t)} T ) \bar\ltimes U
$$

## Semijoins and antijoins

A semijoin after a degenerate antijoin can be reordered:

$$
R \ltimes_{p(r,t)} ( T \bar\ltimes_{q(r,u)} U ) =
( R \ltimes_{p(r,t)} T ) \bar\ltimes_{q(r,u)} U
$$

And the simpler case

$$
R \ltimes_{p(r,t)} ( T \bar\ltimes_{q(r,t)} U ) =
( R \ltimes_{p(r,t) \land q(r,t)} T ) \bar\ltimes U
$$

## Semijoins and semijoins

A semijoin after a degenerate semijoin can be reordered:

$$
R \ltimes_{p(r,t)} ( T \ltimes_{q(r,u)} U ) =
( R \ltimes_{p(r,t)} T ) \ltimes_{q(r,u)} U
$$

Or the simpler case
$$
R \ltimes_{p(r,t)} ( T \ltimes_{q(r,t)} U ) =
( R \ltimes_{p(r,t) \land q(r,t)} T ) \ltimes U
$$

## Antijoins

## Shit
In SQL:

```sql
CREATE TEMP TABLE R (x int, y int, z int);
CREATE TEMP TABLE T (c int, d int);
CREATE TEMP TABLE U (v int, w int);

EXPLAIN (COSTS OFF)
SELECT R.y
FROM R
WHERE true
  AND EXISTS (
    SELECT 1
    FROM T
    WHERE R.x = T.c
    AND NOT EXISTS (
        SELECT 1 from U
        where R.z = U.w ) );
```

Or in symbols:

$$
R \ltimes_{p(r,u)} (T \bar\ltimes_{q(r,u)} U)
$$

Denote $\large{\sigma}_{q(r,u)U}$ by $U_r$, then the above can be more clearly expressed as

$$
R \ltimes_{p(r,s)} (T \bar\ltimes U_r)
$$

Notice the first join $T \bar\ltimes U_r$ here is a degenerate antijoin:

$$
T \bar\ltimes U_r =
\begin{cases}
T & \text{if } U_r = \emptyset\\
\emptyset & \text{otherwise}
\end{cases}
$$

This allows for reordering that isn't otherwise possible in nondegenerate cases:

## Inner Join

$$
R \Join_{p(r,u)} (T \bar\ltimes U_r ) =
(R \Join_{p(r,u)} T ) \bar\ltimes_{q(r,u)} U
$$

## Semi Join

$$
R \ltimes_{p(r,u)} (T \bar\ltimes U_r ) =
(R \ltimes_{p(r,u)} T) \bar\ltimes_{q(r,u)} U
$$

But of course not right semi join:

$$
(T \bar\ltimes U_r ) \ltimes_{p(r,u)} R \neq
T \bar\ltimes U_r (T \ltimes_{p(r,u)} R )
$$
