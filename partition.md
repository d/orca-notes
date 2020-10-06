# Postgres 12 Partitioning and ORCA

# Actions / Open Questions to research

1. Plan A: we are gonna go full gung-ho on Append + PS, ditch DTS, DIS, DBIS.

1. Confirm claims of high memory usage if we drop DynamicTableScan
   1. If we can't drop DTS: regroup and restrategize
   1. Finding: With 16384 partitions, planner only onsumed 142 MB, and executing the sequential scans (16384 of them) costs about 165 MB of RAM (10K each).

      |   |SELECT|EXPLAIN ANALYZE|
      |---|---|---|
      |QD|142 MB|438 MB|
      |QE|172 MB|178 MB|

   1. Finding: the `statement_mem` calculation is significantly overestimates the memory usage (about 10X).

1. See if the new catalog has adequate information to model PartConstraints
   1. It has more: refine our model? Drop the extra on the floor?
   1. It has less: regroup and discuss what to do

1. Plans for indexes on partitioned tables
   1. Contention: partial scans (indexes).
   1. No contention: we definitely need to support foreign partitions


# Insights
1. GPDB7's Append node has functionality to do selection on its children Scan nodes, so as to only execute a subset based on certain conditions. This can thus support Dynamic Partition Elimination (DPE) for cases that use PARAMS, eg: Nested loop joins, external params, subplans (currently not supported at all).
```
-> Nested Loop Join
    join cond: foo.a = bar.pk
    -> Scan on foo
    -> Append*
        -> Scan on bar_p1
        -> Scan on bar_p2

* Append contains pruning steps using an outer ref to foo.a (as a PARAM)
```
2. To perform DPE with Hash joins, we will need to use another operator: Partition Selector. Supporting DPE with Hash joins is the only reason we need to have the Partition Selector operator.
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
3. The Partition Selector <-> Append relationship now needs to be only many-1 (and *not* many-many). That is, each Partition Selector needs to affect only one Append node. However, an Append node can benefit from multiple Partition Selectors
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
4. We no longer need Dynamic XXX Scan, since all of its functionality is capture by the new Append operator.

> ***TODO: Confirm claims of high memory usage if we drop this!***

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

## Partial Scans with Indexes and Foreign Tables

# More Possibilities
Things that ORCA doesn't do, but we've wanted to do for a long time.

## Combined static and runtime pruning

Motivating example (taken from [gporca issue 565][gporca-issue-565])

[gporca-issue-565]: https://github.com/greenplum-db/gporca/issues/565

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

# Parking Lot

