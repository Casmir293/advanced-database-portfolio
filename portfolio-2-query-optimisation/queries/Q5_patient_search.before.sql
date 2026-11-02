-- Q5 Records desk: find a patient from a partial name ("Emeka ... Chukwu-something").
SELECT hospital_no, first_name, last_name, date_of_birth, phone
FROM patient
WHERE last_name ILIKE '%chukw%' AND first_name ILIKE '%emek%'
ORDER BY last_name, first_name;
