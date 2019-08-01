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
  AND NOT EXISTS(SELECT 1
                 FROM pg_constraint
                 WHERE objid = oid
                   AND contype = 'c'
                   AND classid = 'pg_constraint'::regclass)
  AND objid > 16000
GROUP BY objid, classid, objsubid, deptype;

CREATE INDEX segundo_abcd ON foo_1_prt_segundo (a, b, c, d);
CREATE INDEX foo_abcd ON foo (a, b, c, d);
DROP INDEX foo_abcd;

-- SELECT classid, describe(classid, objid, 0) FROM dependents_of('foo');
-- SELECT * FROM constraints_of('foo');
SELECT *
FROM yolo;
SELECT *
FROM indices_of('foo');

ALTER TABLE foo
    ALTER PARTITION segundo ADD PARTITION echo START (204) END (206);
SELECT *
FROM indices_of('foo');

CREATE TABLE bar
(
    LIKE foo
);
ALTER TABLE foo
    ALTER PARTITION segundo EXCHANGE PARTITION echo WITH TABLE bar;
DROP TABLE bar;
