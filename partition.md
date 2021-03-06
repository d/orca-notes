# Postgres 12 Partitioning and ORCA

# Possible story structure.

1. End to end for static partitioning
	- Delete most of the old partition selection logic in ORCA
	- Implement basic static pruning in ORCA
	- Implement translation from static filter expression to `part_prune_info` steps (Easier because it requires fewer operators)
2. End to end for dynamic partition for NLJ
	- Recognize dynamic alternative for NLJ joins. 
	- Questions:
		- How to make sure it's an alternative? As in, should we even considering no doing DPE for NLJ even when it is possible? 
		- What if the PS is no very selective or expensive?
		- How do we cost such plans?
	- Is the PARAM handling implemented fully in ORCA yet?
	- What happens when the PARAM ends up under a Motion/Materialize? If we do not enforce a PS (like in GPDB6), there will be no (easy) way to ensure that Motions are placed underneath the PS.
3. End to end for DPE for HJ
	- Implement simplified Partition Propagation logic. (Worst case scenario: resurrect the old code)
	- Ensure we can do *nested* and *multiple* DPEs
4. End of end for DPE with static, NLJ & HJ combined. (This shouldn't really take more work, just putting it here to make sure it is checked)

# Background: Partitioning
Complete reference available in [PostgreSQL 12 Declarative Partitioning documentation][ddl-partitioning].

[ddl-partitioning]: https://www.postgresql.org/docs/12/ddl-partitioning.html#DDL-PARTITIONING-DECLARATIVE

The following forms of partitioning are supported

type | expr? | multi-key? | opclass
---|---|---|---
Range partitioning | Yes | Yes | btree
List partitioning | Yes | No | btree (surprise)
Hash partitioning | Yes | Yes | hash

## Partitioned Table

```sql
CREATE TABLE measurement (
    city_id         int not null,
    logdate         date not null,
    peaktemp        int,
    unitsales       int
) PARTITION BY RANGE (logdate);
```

## Partitions and Sub-Partitioning

```sql
CREATE TABLE measurement_y2006m02 PARTITION OF measurement
    FOR VALUES FROM ('2006-02-01') TO ('2006-03-01');
```

```sql
CREATE TABLE measurement_y2006m02 PARTITION OF measurement
    FOR VALUES FROM ('2006-02-01') TO ('2006-03-01')
    PARTITION BY RANGE (peaktemp);
```

is partition\partitioned? | no | yes
---|---|---
no | standalone table | "root"
yes | leaf | sub partition

# Insights

## Append

GPDB7's `Append` node has functionality to do selection on its children (e.g. `Seq Scan` nodes, but it can be any other type of node), so as to only execute a subset based on certain conditions.
This can thus support Dynamic Partition Elimination (DPE) for cases that use PARAMS, eg: Nested loop joins, external params, subplans (currently not supported at all).

```
-> Nested Loop
    Join Filter: foo.a = bar.pk
    -> Seq Scan on foo
    -> Append*
        -> Seq Scan on bar_p1
        -> Seq Scan on bar_p2

* Append contains pruning steps using an outer ref to foo.a (as a PARAM)
```

## Partition Selector

To perform DPE with Hash joins, we will need to use another operator: Partition Selector. Supporting DPE with Hash joins is the only reason we need to have the Partition Selector operator.

```
-> Hash Join
    hash cond: foo.a = bar.pk1
    join cond: foo.b < bar.pk2
    -> Append*
        -> Scan on bar_p1
        -> Scan on bar_p2
    -> Hash
        -> Partition Selector**
            -> Scan on foo

* Append now just uses the pruned oids from it's Partition Selector
** Partition Selector uses both bar.pk1 & bar.pk2 to determine the pruned list.
```

## Multiple Partition Selectors

The Partition Selector <-> Append relationship now needs to be only many-1 (and *not* many-many). That is, each Partition Selector needs to affect only one Append node. However, an Append node can benefit from multiple Partition Selectors

```
-> Hash Join
    -> Hash Join
        -> Append
            -> Scan bar_p1
            -> Scan bar_p2
        -> Hash
            -> Partition Selector
                -> Scan on foo
    -> Hash
        -> Partition Selector
            -> Scan on jazz

-> Nested Loop Join
    -> Scan on jazz
    -> Hash Join
        -> Append*
            -> Scan bar_p1
            -> Scan bar_p2
        -> Hash
            -> Partition Selector
                -> Scan on foo

* Append benefits from both NLJ PARAMs as well as Partition Selector's pruned oids.
```

## Au Revoir Dynamc FooScan

We no longer need Dynamic XXX Scan, since all of its functionality is capture by the new Append operator.

## More Insights

1. Static pruning doesn't need enforcement, it should always happen
2. Nested Loop pruning (the one that `Append` does by itself) doesn't need enforcement, it should happen whenever possible (exceptions: motions, material, and shit)
3. Partition Selection as an enforced property is reserved only for runtime pruning utilizing Hash Join.

# Short-Term Goal Post

One level partitioning: Planning for a partitioned table, none of whose partitions are partitioned.

# Unknown

## Static Pruning

Refer to next section

## Runtime Pruning

Precisely how (and when) is ORCA gonna generate an Expression-like thing that can be easily translated into a Postgres `PartitionPruneInfo` object?

* Proposal 1: `= 1`, `AND`, `< bar.c`
* Proposal 2: more mirroring of the `PartitionPruneInfo` to avoid "flattening the expression tree into array"

What are the trade-offs? Which one is less awkward? Decisions here also have an impact on static pruning.

## Foreign scans

How is this gonna look in ORCA?

# Feature Parity

## Static Pruning

DynamicTableScan should contain explicit information about static pruning

```XML
<dxl:DynamicTableScan>
<dxl:Properties />
<dxl:ProjList />
<dxl:Filter />
<dxl:PruneInfos>
  <dxl:PartitionedRelPruneInfo>
    <dxl:InitPruningSteps>
    </dxl:InitPruningSteps>
  </dxl:PartitionedRelPruneInfo>
</dxl:PruneInfos>
<dxl:TableDescriptor Mdid="0.319609.1.0" TableName="listfoo" />
</dxl:DynamicTableScan>
```

The hypothetical `dxlPartitionedRelPruneInfo` (final name TBD) would be translated into PartitionedRelPruneInfo nodes in Postgres. The translator can then execute them to get the surviving subset and record it into `DynamicSeqScan::active_parts` (final name TBD).

```C
typedef struct DynamicSeqScan
{
	/* Fields shared with a normal SeqScan. Must be first! */
	SeqScan		seqscan;

	/*
	 * List of leaf partition OIDs to scan.
	 */
	List	   *partOids;

	/* indexes of all partitions that survive static pruning */
	BitmapSet  *active_parts;
} DynamicSeqScan;
```

## What Shreedhar Says About Static Pruning

ORCA plan (Expr):

```
PartitionSelector
  UberScan
```

Expr2DXL

1. Use the predicates in partition selector to prune some partitions
2. Use the remaining parts and expand the uber scan to an DXL Append with one DXLTableScan for each remaining partition


## Partial Scans
What do we do to about partial scans?

* It seems easy to execute, we know exactly what a partial scan plan _should_ look
* There seems to be insurmountable difficult in planning optimally for this.
* Specifically, the following kinds of plans are "easy to execute" but very very challenging to optimize (hint: exponential search space):
  * partition-wise aggregate
  * partition-wise join
  * partition-wise index path
* Note: partition-wise sort should _not_ be that hard to plan.
* Jesse's recommendation: there's a small baby, but this is 99% bathwater, please throw it away and never look back
* Shreedhar: What if PM regrets abandoning the baby and comes back to the adoption agency and demands a return?

## Runtime Pruning

The partition selector node has been reshaped into this:

```C
typedef struct PartitionSelector
{
	Plan		plan;

	struct PartitionPruneInfo *part_prune_info;
	int32		paramid;	/* result is stored here */

} PartitionSelector;
```

Currently, Partition Selector DXL looks like this
```xml
<dxl:PartitionSelector RelationMdid="0.322247.1.1" PartitionLevels="1" ScanId="1">
  <dxl:Properties />
  <dxl:ProjList/>
  <dxl:PartEqFilters />
  <dxl:PartFilters />
  <dxl:ResidualFilter />
  <dxl:PropagationExpression />
</dxl:PartitionSelector>
```

I suggest we change it to mirror the `PartitionSelector` node above:

```xml
<dxl:PartitionSelector RelationMdid="0.322247.1.1" PartitionLevels="1" ScanId="1">
  <dxl:Properties />
  <dxl:ProjList/>
  <dxl:PartitionPruneInfo>
  </dxl:PartitionPruneInfo>
</dxl:PartitionSelector>
```

`PartitionSelector::part_prune_info` is a `PartitionPruneInfo` node,
when evaluated (c.f. `ExecCreatePartitionPruneState` and `ExecFindMatchingSubPlans`),
it will return a `Bitmapset` representing the subset of partitions that survives pruning.

## Handling more than one level of partitioning

## Dynamic Index Scan
No different than just an `Append` over a bunch of `Index Scan`

## Partial Scans with Indexes and Foreign Tables

Partial Scan in the context of indexes is dead.

Partial Scan in the context of mixed foreign partitions and non-foreign partitions lives on.

# More Possibilities
Things that ORCA doesn't do, but we've wanted to do for a long time.

## Combined static and runtime pruning

Motivating example (taken from [gporca issue 565][gporca-issue-565])

[gporca-issue-565]: https://github.com/greenplum-db/gporca/issues/565

```sql
CREATE TEMP TABLE foo (a int, b smallint) PARTITION BY RANGE(b);
CREATE TEMP TABLE foo_0 PARTITION OF foo FOR VALUES FROM (0) TO (10);
CREATE TEMP TABLE foo_10 PARTITION OF foo FOR VALUES FROM (10) TO (20);
CREATE TEMP TABLE foo_20 PARTITION OF foo FOR VALUES FROM (20) TO (30);
CREATE TEMP TABLE foo_30 PARTITION OF foo FOR VALUES FROM (30) TO (40);
CREATE TEMP TABLE foo_40 PARTITION OF foo FOR VALUES FROM (40) TO (MAXVALUE);

SELECT * FROM foo WHERE b > 20 AND b < $1;

  oid   |  oid   
--------+--------
 468792 | foo
 468795 | foo_0
 468798 | foo_10
 468801 | foo_20
 468804 | foo_30
 468807 | foo_40
```

<details><summary>plan snippet</summary>

```
:first_partial_plan 3 
:part_prune_info 
   {PARTITIONPRUNEINFO 
   :prune_infos ((
      {PARTITIONEDRELPRUNEINFO 
      :rtindex 1 
      :present_parts (b 2 3 4)
      :nparts 5 
      :subplan_map  -1 -1 0 1 2 
      :subpart_map  -1 -1 -1 -1 -1 
      :relid_map  0 0 468801 468804 468807 
      :initial_pruning_steps (
         {PARTITIONPRUNESTEPOP 
         :step.step_id 0 
         :opstrategy 1 
         :exprs (
            {PARAM 
            :paramkind 0 
            :paramid 1 
            :paramtype 23 
            :paramtypmod -1 
            :paramcollid 0 
            :location 60
            }
         )
         :cmpfns (o 2190)
         :nullkeys (b)
         }
         {PARTITIONPRUNESTEPOP 
         :step.step_id 1 
         :opstrategy 5 
         :exprs (
            {CONST 
            :consttype 23 
            :consttypmod -1 
            :constcollid 0 
            :constlen 4 
            :constbyval true 
            :constisnull false 
            :location 49 
            :constvalue 4 [ 20 0 0 0 0 0 0 0 ]
            }
         )
         :cmpfns (o 2190)
         :nullkeys (b)
         }
         {PARTITIONPRUNESTEPCOMBINE 
         :step.step_id 2 
         :combineOp 1 
         :source_stepids (i 0 1)
         }
      )
      :exec_pruning_steps <> 
      :execparamids (b)
      }
   ))
   :other_subplans (b)
   }
```
</details>


## Vision for foreign scan

Alternative one: dynamic pruning for the non-foreign tables:
```
Nest Loop
  Join Cond: bar.c = foo.pk
  Redistribute
    Seq Scan bar
  Append
    Seq Scan foo_1
    Seq Scan foo_2
    Redistribute
      Append
        Foreign Scan ext_foo_3
        Foreign Scan ext_foo_4
```


Alternative 2: static pruning only
```
Nest Loop
  Join Cond: bar.c = foo.pk
  Seq Scan bar
  Redistribute
  Append
    Seq Scan foo_1
    Seq Scan foo_2
    Foreign Scan ext_foo_3
    Foreign Scan ext_foo_4
```

## "Intersecting" multiple partition selectors
## Proper runtime pruning under Nest Loop
## Hetero

# Setup

```sql
CREATE TABLE grandma (a int, b int, pk int) PARTITION BY RANGE(pk);
CREATE TABLE mom PARTITION OF grandma FOR VALUES FROM (0) TO (10);
CREATE TABLE aunt PARTITION OF grandma FOR VALUES FROM (-10) TO (0);

CREATE TABLE abuela (a int, b int, pk int) PARTITION BY LIST(pk);
CREATE TABLE mama PARTITION OF abuela FOR VALUES IN (40, 42);
CREATE TABLE tia PARTITION OF abuela FOR VALUES IN (-3, -2, -1);

CREATE TABLE grandpa (a int, b int, pk int) PARTITION BY RANGE(b);
CREATE TABLE dad PARTITION OF grandpa FOR VALUES FROM (0) TO (20) PARTITION BY RANGE(pk);
CREATE TABLE me PARTITION OF dad FOR VALUES FROM (0) TO (43);
CREATE TABLE bro PARTITION OF dad FOR VALUES FROM (-43) TO (0);
CREATE TABLE older_uncle PARTITION OF grandpa FOR VALUES FROM (20) TO (40) PARTITION BY RANGE(pk);
CREATE TABLE aaron PARTITION OF older_uncle FOR VALUES FROM (0) TO (2);
CREATE TABLE abel PARTITION OF older_uncle FOR VALUES FROM (4) TO (6);
CREATE TABLE younger_uncle PARTITION OF grandpa FOR VALUES FROM (40) TO (60);

SELECT oid, oid::regclass
FROM pg_class
WHERE oid = ANY
  (ARRAY['grandma', 'mom', 'aunt', 'abuela', 'mama', 'tia', 'grandpa', 'dad', 'me', 'bro', 'older_uncle', 'aaron', 'abel', 'younger_uncle']::regclass[])
ORDER BY 1;
```

Sample output:

```
  oid  |      oid
-------+---------------
 67877 | grandma
 67880 | mom
 67883 | aunt
 67886 | abuela
 67889 | mama
 67892 | tia
 67895 | grandpa
 67898 | dad
 67901 | me
 67904 | bro
 67907 | older_uncle
 67910 | aaron
 67913 | abel
 67916 | younger_uncle
(14 rows)
```

# When is pruneinfos length > 1 in outerlist? Inner list?

```sql
SELECT *
FROM (
	SELECT *
	FROM grandma
	UNION ALL
	SELECT *
	FROM grandpa
) t
WHERE pk > $1;
```

<details>
<summary>Annotated plan snipet</summary>

```
:part_prune_info
   {PARTITIONPRUNEINFO
   :prune_infos ((
      {PARTITIONEDRELPRUNEINFO
      :rtindex 4 # rti=4: grandma
      :present_parts (b 0 1)
      :nparts 2
      :subplan_map  0 1 # the positions of the scan plans for surviving partitions
      :subpart_map  -1 -1 # none of the partitions need further pruning
      :relid_map  67883 67880 # aunt mom (in range order, not oid order)
      :initial_pruning_steps (
         {PARTITIONPRUNESTEPOP
         :step.step_id 0
         :opstrategy 5 # > $1
         :exprs (
            {PARAM
            :paramkind 0
            :paramid 1
            :paramtype 23
            :paramtypmod -1
            :paramcollid 0
            :location 112
            }
         )
         :cmpfns (o 351) # btint4cmp(int,int)
         :nullkeys (b) # only relevant to hash partitioning
         }
      )
      :exec_pruning_steps <>
      :execparamids (b)
      }
   )
   (
      {PARTITIONEDRELPRUNEINFO
      :rtindex 5 # rti=5: grandpa
      :present_parts (b 0 1 2)
      :nparts 3
      :subplan_map  -1 -1 6 # the first two (dad, older_uncle) need further pruning (subpartitions), while younger_uncle (the third) will reach a scan plan (leaf)
      :subpart_map  1 2 -1 # ditto
      :relid_map  67898 67907 67916 # dad, older_uncle, younger_uncle
      :initial_pruning_steps <>
      :exec_pruning_steps <>
      :execparamids (b)
      }
      {PARTITIONEDRELPRUNEINFO
      :rtindex 8 # rti=8: dad
      :present_parts (b 0 1)
      :nparts 2
      :subplan_map  2 3 # after pruning, the surviving partitions will be scanned (each is a leaf)
      :subpart_map  -1 -1
      :relid_map  67904 67901 # bro, me (in range order)
      :initial_pruning_steps (
         {PARTITIONPRUNESTEPOP
         :step.step_id 0
         :opstrategy 5
         :exprs (
            {PARAM
            :paramkind 0
            :paramid 1
            :paramtype 23
            :paramtypmod -1
            :paramcollid 0
            :location 112
            }
         )
         :cmpfns (o 351)
         :nullkeys (b)
         }
      )
      :exec_pruning_steps <>
      :execparamids (b)
      }
      {PARTITIONEDRELPRUNEINFO
      :rtindex 11 # rti=11: older_uncle
      :present_parts (b 0 1)
      :nparts 2
      :subplan_map  4 5 # each is a leaf
      :subpart_map  -1 -1
      :relid_map  67910 67913 # aaron abel
      :initial_pruning_steps (
         {PARTITIONPRUNESTEPOP
         :step.step_id 0
         :opstrategy 5
         :exprs (
            {PARAM
            :paramkind 0
            :paramid 1
            :paramtype 23
            :paramtypmod -1
            :paramcollid 0
            :location 112
            }
         )
         :cmpfns (o 351)
         :nullkeys (b)
         }
      )
      :exec_pruning_steps <>
      :execparamids (b)
      }
   ))
   :other_subplans (b)
   }
}
```

</details>

# Postgres 12 init pruning over list partitioned table:

```sql
SELECT * FROM abuela WHERE pk NOT IN (40, 42, 44);
```

EXPLAIN:
```
 Append
   Subplans Removed: 1
   ->  Seq Scan on tia
         Filter: (pk <> ALL (ARRAY[$1, $2, $3]))
```

<details>
<summary>Details inside of `Append`</summary>

```
:part_prune_info
   {PARTITIONPRUNEINFO
   :prune_infos ((
      {PARTITIONEDRELPRUNEINFO
      :rtindex 1
      :present_parts (b 0 1)
      :nparts 2
      :subplan_map  0 1
      :subpart_map  -1 -1
      :relid_map  67390 67387
      :initial_pruning_steps (
         {PARTITIONPRUNESTEPOP
         :step.step_id 0
         :opstrategy 0
         :exprs (
            {PARAM
            :paramkind 0
            :paramid 1
            :paramtype 23
            :paramtypmod -1
            :paramcollid 0
            :location 70
            }
         )
         :cmpfns (o 351)
         :nullkeys (b)
         }
         {PARTITIONPRUNESTEPOP
         :step.step_id 1
         :opstrategy 0
         :exprs (
            {PARAM
            :paramkind 0
            :paramid 2
            :paramtype 23
            :paramtypmod -1
            :paramcollid 0
            :location 74
            }
         )
         :cmpfns (o 351)
         :nullkeys (b)
         }
         {PARTITIONPRUNESTEPOP
         :step.step_id 2
         :opstrategy 0
         :exprs (
            {PARAM
            :paramkind 0
            :paramid 3
            :paramtype 23
            :paramtypmod -1
            :paramcollid 0
            :location 78
            }
         )
         :cmpfns (o 351)
         :nullkeys (b)
         }
         {PARTITIONPRUNESTEPCOMBINE
         :step.step_id 3
         :combineOp 1
         :source_stepids (i 0 1 2)
         }
      )
      :exec_pruning_steps <>
      :execparamids (b)
      }
   ))
   :other_subplans (b)
   }
```

</details>

# Notes & Feedback
1. From Shreedhar: Justify many-to-many between Append and Partition Selectors

# Due Diligence

## 16384 Partitions Set-Up

```sql
-- 16384 partitions
CREATE SCHEMA foo_16384;
CREATE TABLE foo_16384.foo(a int, b smallint, c int)
PARTITION BY RANGE (b);

SET client_min_messages TO warning;
SELECT format('CREATE TABLE %s partition OF %s FOR VALUES FROM (%s) TO (%s)', "partition", root, i, i+1)
FROM (
    SELECT format('foo_16384.foo_%s', i) AS partition, 'foo_16384.foo' AS root, i
    FROM generate_series(0, 16384 - 1) i
) t; \gexec
RESET client_min_messages;

INSERT INTO foo_16384.foo (b) SELECT generate_series(0, 16384 - 1);
```

## Claims of High Memory Usage of `SeqScan`s

Finding: With 16384 partitions, QD only onsumes 142 MB, and executing the sequential scans (16384 of them) costs about 165 MB of RAM (10K each).

|   |SELECT|EXPLAIN ANALYZE|
|---|---|---|
|QD|142 MB|438 MB|
|QE|172 MB|178 MB|

Finding: the `statement_mem` calculation is significantly overestimates the memory usage (about 10X).

## Claims of Planner Slowness:

Query \ Product | Greenplum 7 planner | Postgres 12 | Postgres 13
---|---|---|---
`SELECT 1 FROM foo` | 14860.484 ms (00:14.860) | 380.452 ms | 417.143 ms
`CREATE TEMP TABLE foo1 AS SELECT a FROM foo` | 83667.647 ms (01:23.668) | 383.817 ms | 434.602 ms
`EXPLAIN SELECT 1 FROM foo` | 18542.430 ms (00:18.542) | 1903.545 ms (00:01.904) | 323.145 ms
`SELECT 1 FROM foo JOIN foo bar USING (a)` | 865703.271 ms (14:25.703) | 422854.283 ms (07:02.854) | 366815.695 ms (06:06.816)
`CREATE TEMP TABLE foo2 AS SELECT a FROM foo JOIN foo bar USING (a)` | 582529.987 ms (09:42.530) | 292123.332 ms (04:52.123) | 267593.284 ms (04:27.593)
`EXPLAIN SELECT 1 FROM foo JOIN foo bar USING (a)` | 627897.107 ms (10:27.897) | 337578.763 ms (05:37.579) | 315750.860 ms (05:15.751)

# Parking Lot

# Garage

# Plan A (a.k.a the only plan)
> Gung-ho on Append + PS, ditch DTS, DIS, DBIS.

## Implementation Plan

1. Translating DTS -> a number of SeqScan. This is should be pretty easy, and we will ignore any partition pruning. `SELECT 1 FROM foo;`
1. Static pruning done in ORCA (done on top of Ext Scan PR). 
    - Idea is to look for a contradiction between Select predicates & partitioning constraints (not partconstraints!) of each leaf partition.
    - If this needs to be done in ORCA, we would need to translate all the partition constraints for each leaf table in a partitioned table (is that very expensive?)
    - Temporary solution: Implement static pruning using PartitionedRelPruneInfo::initial_pruning_steps using Consts. This is executed _once_ per node, during ExecInitNode().
    - Although, this may not be that bad, except the cost of all the work & memory of extra operators. Of ourse, it also bloats up the plan size.
    - Can this be done as a transform?
1. Rewrite Logical/Physical DynamicTableScan (call it MultiTableScan whatever): Add/remove the following members:
    1. [A] oids: The oids of relations that this nodes will expand into. So, static pruning will just remove members from this list.
    2. [A] contains_foreign_scans: Either the DTS starts of managing both, and the is split in an xform; OR we split it early on in the translator.
    3. [R] partial_scan: no longer needed - yay! 5. Removing partial scan code, part constraints
1. Rework part index map, part filter map and the way in which we do partition property management.

## Open Questions

- [x] Confirm claims of high memory usage if we drop DynamicTableScan
   1. If we can't drop DTS: regroup and restrategize
   1. [Dispelling claims of high memory usage of `SeqScan`s](#Claims-of-High-Memory-Usage-of-SeqScans)
   1. [Investigate claims of planner slowness](#Claims-of-Planner-Slowness). TL;DR: upstream planner is fast in simple scan type queries, but it spends a lot of time planning just a join between two partitioned tables (with 16384 partitions). Greenplum 7 planner seems to be oddly inefficient even with the simple scan type queries.
   1. A self join on a partitioned table with 16384 partitions takes more than 6 minutes in Greenplum 7 planner. Real question: if we can magically generate this plan would the executor chill?
   1. `SELECT 1 from foo JOIN foo USING (a)` is 8min+ (OOM) in GPDB 6 and 8min+ (didn't complete) GPDB 7

- [ ] See if the new catalog has adequate information to model PartConstraints
   1. It has more: refine our model? Drop the extra on the floor?
   1. It has less: regroup and discuss what to do
   1. Random addendum: can a partition be distributed differently from its ancestors?
      1. Can the distribution key(s) be different?
      1. Can the distribution column(s) be the same, however a partition uses different opclasses than its parent
      1. Can the `numsegments` be different?

- [ ] "Hello world" of PartitionPropagationSpec. A "Require-Derive" cycle.

- [ ] Plans for indexes on partitioned tables
   1. Contention: partial scans (indexes).
   1. No contention: we definitely need to support foreign partitions

