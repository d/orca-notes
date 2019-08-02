CREATE TABLE foo
(
    a int,
    b int,
    c int,
    d int
) DISTRIBUTED BY (a)
    PARTITION BY RANGE (b)
        SUBPARTITION BY RANGE (c)
        (PARTITION primero START (0) END (42) (
            SUBPARTITION alpha START(100) END(102),
            SUBPARTITION beta START(102) END(104),
            SUBPARTITION charlie START(200) END(202)
            ),
        PARTITION segundo START (42) END (82) (
            SUBPARTITION delta START(202) END(204)
            )
        );

SELECT *
FROM indices_of('foo');

CREATE TEMP VIEW yolo AS
SELECT classid::regclass,
       describe(classid, objid, objsubid)                     dependent,
       array_agg(describe(refclassid, refobjid, refobjsubid)) referenced,
       deptype
FROM pg_depend dep
WHERE deptype IN ('P', 'S', 'I', 'a')
  -- filter out the clutter of check constraints
  AND NOT EXISTS(SELECT 1
                 FROM pg_constraint
                 WHERE objid = oid
                   AND contype = 'c'
                   AND classid = 'pg_constraint'::regclass)
  AND objid > 16000
GROUP BY objid, classid, objsubid, deptype;

ALTER TABLE foo
    ADD CONSTRAINT foo_pk PRIMARY KEY (a, b, c, d);

SELECT *
FROM indices_of('foo');

CREATE TABLE jazz
(
    e int,
    f int
);
EXPLAIN
    SELECT e, f
    FROM jazz
             LEFT JOIN foo
                       ON e = a AND 0 = b AND 100 = c AND f = d;
