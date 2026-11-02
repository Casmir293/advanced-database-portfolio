-- Row counts and on-disk size of every table in schema hms
SET search_path = hms, public;
SELECT c.relname                                      AS table_name,
       to_char(c.reltuples::bigint, 'FM9,999,999')    AS approx_rows,
       pg_size_pretty(pg_total_relation_size(c.oid))  AS total_size
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'hms' AND c.relkind = 'r'
ORDER BY c.reltuples DESC;
