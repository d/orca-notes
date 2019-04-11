### SETUP

```
CREATE TABLE foo (a, b) AS (VALUES (1, 2), (2, 3), (4, 5), (5, 6), (6, 7)) DISTRIBUTED BY (a);
CREATE TABLE bar (c, d) AS (VALUES (41, 42), (42, 43), (44, 45), (45, 46), (46, 7)) DISTRIBUTED BY (c);
```


### Degrading a `FULL JOIN` to a `LEFT JOIN`

```sql
EXPLAIN SELECT d FROM foo FULL OUTER JOIN bar ON a = c WHERE b BETWEEN 5 and 9;
```

ORCA plan:
```
                                                      QUERY PLAN
----------------------------------------------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.00..2586.01 rows=6 width=4)
   ->  Result  (cost=0.00..2586.01 rows=2 width=4)
         Filter: ((share0_ref2.b >= 5) AND (share0_ref2.b <= 9))
         ->  Sequence  (cost=0.00..2586.01 rows=6 width=8)
               ->  Shared Scan (share slice:id 1:0)  (cost=0.00..431.00 rows=4 width=1)
                     ->  Materialize  (cost=0.00..431.00 rows=4 width=1)
                           ->  Seq Scan on foo  (cost=0.00..431.00 rows=4 width=38)
               ->  Sequence  (cost=0.00..2155.01 rows=6 width=8)
                     ->  Shared Scan (share slice:id 1:1)  (cost=0.00..431.00 rows=4 width=1)
                           ->  Materialize  (cost=0.00..431.00 rows=4 width=1)
                                 ->  Seq Scan on bar  (cost=0.00..431.00 rows=4 width=38)
                     ->  Append  (cost=0.00..1724.01 rows=6 width=8)
                           ->  Hash Left Join  (cost=0.00..862.01 rows=5 width=76)
                                 Hash Cond: (share0_ref2.a = share1_ref2.c)
                                 ->  Shared Scan (share slice:id 1:0)  (cost=0.00..431.00 rows=4 width=38)
                                 ->  Hash  (cost=431.00..431.00 rows=4 width=38)
                                       ->  Shared Scan (share slice:id 1:1)  (cost=0.00..431.00 rows=4 width=38)
                           ->  Result  (cost=0.00..862.00 rows=2 width=76)
                                 ->  Hash Anti Join  (cost=0.00..862.00 rows=2 width=38)
                                       Hash Cond: (share1_ref3.c = share0_ref3.a)
                                       ->  Shared Scan (share slice:id 1:1)  (cost=0.00..431.00 rows=4 width=38)
                                       ->  Hash  (cost=431.00..431.00 rows=4 width=4)
                                             ->  Shared Scan (share slice:id 1:0)  (cost=0.00..431.00 rows=4 width=4)
 Optimizer: PQO version 3.33.0
(24 rows)
```

Expected plan (this shoud turn `foo FULL JOIN bar` into `foo LEFT JOIN bar`:
```
                                                QUERY PLAN
-----------------------------------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.00..2586.01 rows=6 width=4)
   ->  Result  (cost=0.00..2586.01 rows=2 width=4)
         Filter: ((share0_ref2.b >= 5) AND (share0_ref2.b <= 9))
         ->  Sequence  (cost=0.00..2586.01 rows=6 width=8)
               ->  Shared Scan (share slice:id 1:0)  (cost=0.00..431.00 rows=4 width=1)
                     ->  Materialize  (cost=0.00..431.00 rows=4 width=1)
                           ->  Seq Scan on foo  (cost=0.00..431.00 rows=4 width=38)
               ->  Sequence  (cost=0.00..2155.01 rows=6 width=8)
                     ->  Shared Scan (share slice:id 1:1)  (cost=0.00..431.00 rows=4 width=1)
                           ->  Materialize  (cost=0.00..431.00 rows=4 width=1)
                                 ->  Seq Scan on bar  (cost=0.00..431.00 rows=4 width=38)
                     ->  Hash Left Join  (cost=0.00..862.01 rows=5 width=76)
                           Hash Cond: (share0_ref2.a = share1_ref2.c)
                           ->  Shared Scan (share slice:id 1:0)  (cost=0.00..431.00 rows=4 width=38)
                           ->  Hash  (cost=431.00..431.00 rows=4 width=38)
                                 ->  Shared Scan (share slice:id 1:1)  (cost=0.00..431.00 rows=4 width=38)
 Optimizer: PQO version 3.33.0
(17 rows)
```

Or better, without CTE's:

```
                                   QUERY PLAN
-------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.00..2586.01 rows=6 width=4)
   ->  Result  (cost=0.00..2586.01 rows=2 width=4)
         Filter: ((share0_ref2.b >= 5) AND (share0_ref2.b <= 9))
         ->  Hash Left Join  (cost=0.00..862.01 rows=5 width=76)
               Hash Cond: (share0_ref2.a = share1_ref2.c)
               ->  Seq Scan on foo  (cost=0.00..431.00 rows=4 width=38)
               ->  Hash  (cost=431.00..431.00 rows=4 width=38)
                     ->  Seq Scan on bar  (cost=0.00..431.00 rows=4 width=38)
 Optimizer: PQO version 3.33.0
(9 rows)
```

### Degrading a `FULL JOIN` to a `RIGHT JOIN`

Similarly, for the following query

```sql
EXPLAIN SELECT d FROM foo FULL OUTER JOIN bar ON a = c WHERE d BETWEEN 5 and 9;
```

ORCA generates such a plan:
```
                                                      QUERY PLAN
----------------------------------------------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.00..2586.01 rows=1 width=4)
   ->  Result  (cost=0.00..2586.01 rows=1 width=4)
         Filter: ((share1_ref2.d >= 5) AND (share1_ref2.d <= 9))
         ->  Sequence  (cost=0.00..2586.01 rows=6 width=4)
               ->  Shared Scan (share slice:id 1:0)  (cost=0.00..431.00 rows=4 width=1)
                     ->  Materialize  (cost=0.00..431.00 rows=4 width=1)
                           ->  Seq Scan on foo  (cost=0.00..431.00 rows=4 width=38)
               ->  Sequence  (cost=0.00..2155.01 rows=6 width=4)
                     ->  Shared Scan (share slice:id 1:1)  (cost=0.00..431.00 rows=4 width=1)
                           ->  Materialize  (cost=0.00..431.00 rows=4 width=1)
                                 ->  Seq Scan on bar  (cost=0.00..431.00 rows=4 width=38)
                     ->  Append  (cost=0.00..1724.01 rows=6 width=4)
                           ->  Hash Left Join  (cost=0.00..862.01 rows=5 width=76)
                                 Hash Cond: (share0_ref2.a = share1_ref2.c)
                                 ->  Shared Scan (share slice:id 1:0)  (cost=0.00..431.00 rows=4 width=38)
                                 ->  Hash  (cost=431.00..431.00 rows=4 width=38)
                                       ->  Shared Scan (share slice:id 1:1)  (cost=0.00..431.00 rows=4 width=38)
                           ->  Result  (cost=0.00..862.00 rows=2 width=76)
                                 ->  Hash Anti Join  (cost=0.00..862.00 rows=2 width=38)
                                       Hash Cond: (share1_ref3.c = share0_ref3.a)
                                       ->  Shared Scan (share slice:id 1:1)  (cost=0.00..431.00 rows=4 width=38)
                                       ->  Hash  (cost=431.00..431.00 rows=4 width=4)
                                             ->  Shared Scan (share slice:id 1:0)  (cost=0.00..431.00 rows=4 width=4)
 Optimizer: PQO version 3.33.0
(24 rows)
```

We can really do better. Here's what we expect:
```
                                   QUERY PLAN
-------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.00..2586.01 rows=6 width=4)
   ->  Result  (cost=0.00..2586.01 rows=2 width=4)
         Filter: ((share0_ref2.b >= 5) AND (share0_ref2.b <= 9))
         ->  Hash Left Join  (cost=0.00..862.01 rows=5 width=76)
               Hash Cond: (share0_ref2.a = share1_ref2.c)
               ->  Seq Scan on bar  (cost=0.00..431.00 rows=4 width=38)
               ->  Hash  (cost=431.00..431.00 rows=4 width=38)
                     ->  Seq Scan on foo  (cost=0.00..431.00 rows=4 width=38)
 Optimizer: PQO version 3.33.0
(9 rows)
```

Notice two things above:

1. This effectively degrades `foo FULL JOIN bar` into `foo RIGHT JOIN bar`: we eliminated the `Append` and the `Anti Join`
1. The above plan actually does `bar LEFT JOIN foo` because we don't necessarily want to depend on delivering the `RIGHT JOIN` stories. But a `foo RIGHT JOIN bar` will work too.

### Degrading a `FULL JOIN` to an `INNER JOIN`

```sql
EXPLAIN SELECT d FROM foo FULL OUTER JOIN bar ON a = c WHERE d > b;
```

Actual plan:

```
                                                      QUERY PLAN
----------------------------------------------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.00..2586.00 rows=4 width=4)
   ->  Result  (cost=0.00..2586.00 rows=2 width=4)
         Filter: (share1_ref2.d > share0_ref2.b)
         ->  Sequence  (cost=0.00..2586.00 rows=3 width=8)
               ->  Shared Scan (share slice:id 1:0)  (cost=0.00..431.00 rows=2 width=1)
                     ->  Materialize  (cost=0.00..431.00 rows=2 width=1)
                           ->  Seq Scan on foo  (cost=0.00..431.00 rows=2 width=38)
               ->  Sequence  (cost=0.00..2155.00 rows=3 width=8)
                     ->  Shared Scan (share slice:id 1:1)  (cost=0.00..431.00 rows=2 width=1)
                           ->  Materialize  (cost=0.00..431.00 rows=2 width=1)
                                 ->  Seq Scan on bar  (cost=0.00..431.00 rows=2 width=38)
                     ->  Append  (cost=0.00..1724.00 rows=3 width=8)
                           ->  Hash Left Join  (cost=0.00..862.00 rows=2 width=76)
                                 Hash Cond: (share0_ref2.a = share1_ref2.c)
                                 ->  Shared Scan (share slice:id 1:0)  (cost=0.00..431.00 rows=2 width=38)
                                 ->  Hash  (cost=431.00..431.00 rows=2 width=38)
                                       ->  Shared Scan (share slice:id 1:1)  (cost=0.00..431.00 rows=2 width=38)
                           ->  Result  (cost=0.00..862.00 rows=1 width=76)
                                 ->  Hash Anti Join  (cost=0.00..862.00 rows=1 width=38)
                                       Hash Cond: (share1_ref3.c = share0_ref3.a)
                                       ->  Shared Scan (share slice:id 1:1)  (cost=0.00..431.00 rows=2 width=38)
                                       ->  Hash  (cost=431.00..431.00 rows=2 width=4)
                                             ->  Shared Scan (share slice:id 1:0)  (cost=0.00..431.00 rows=2 width=4)
 Optimizer: PQO version 3.33.0
(24 rows)
```

Expected plan:

```
                                  QUERY PLAN
------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.00..862.00 rows=1 width=4)
   ->  Hash Join  (cost=0.00..862.00 rows=1 width=4)
         Hash Cond: (foo.a = bar.c)
         Join Filter: (bar.d > foo.b)
         ->  Seq Scan on foo  (cost=0.00..431.00 rows=2 width=8)
         ->  Hash  (cost=431.00..431.00 rows=2 width=8)
               ->  Seq Scan on bar  (cost=0.00..431.00 rows=2 width=8)
 Optimizer: PQO version 3.33.0
(8 rows)
```
