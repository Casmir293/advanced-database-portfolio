-- Q5 (optimised): SQL unchanged; pg_trgm GIN indexes make leading-wildcard ILIKE indexable.
SELECT hospital_no, first_name, last_name, date_of_birth, phone
FROM patient
WHERE last_name ILIKE '%chukw%' AND first_name ILIKE '%emek%'
ORDER BY last_name, first_name;
