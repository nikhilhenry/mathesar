/*
This script defines all the necessary functions to be used for custom aggregates in general.

Currently, we have the following custom aggregate(s):
  - msar.peak_time(time): Calculate the 'average time' (interpreted as peak time) for a column.
  - msar.peak_day_of_week(timestamp): Calculate the 'average day of week' (interpreted as peak day of week) for a column.

Refer to the official documentation of PostgreSQL custom aggregates to learn more.
link: https://www.postgresql.org/docs/current/xaggr.html

We'll use snake_case for legibility and to avoid collisions with internal PostgreSQL naming
conventions.
*/


CREATE SCHEMA IF NOT EXISTS msar;

CREATE OR REPLACE FUNCTION 
msar.time_to_degrees(time_ TIME) RETURNS DOUBLE PRECISION AS $$/*
Convert the given time to degrees (on a 24 hour clock, indexed from midnight).

To get the fraction of 86400 seconds passed, we divide time_ by 86400 and then 
to get the equivalent fraction of 360°, we multiply by 360, which is equivalent
to divide by 240. 

Examples:
  00:00:00 =>   0
  06:00:00 =>  90
  12:00:00 => 180
  18:00:00 => 270
*/
SELECT EXTRACT(EPOCH FROM time_) / 240;
$$ LANGUAGE SQL;


CREATE OR REPLACE FUNCTION
msar.degrees_to_time(degrees DOUBLE PRECISION) RETURNS TIME AS $$/*
Convert given degrees to time (on a 24 hour clock, indexed from midnight).

Steps:
- First, the degrees value is confined to range [0,360°)
- Then the resulting value is converted to time indexed from midnight.

To get the fraction of 360°, we divide degrees value by 360 and then to get the
equivalent fractions of 86400 seconds, we multiply by 86400, which is equivalent
to multiply by 240. 

Examples:
    0 => 00:00:00
   90 => 06:00:00
  180 => 12:00:00
  270 => 18:00:00
  540 => 12:00:00
  -90 => 18:00:00

Inverse of msar.time_to_degrees.
*/
SELECT MAKE_INTERVAL(secs => ((degrees::numeric % 360 + 360) % 360)::double precision * 240)::time;
$$ LANGUAGE SQL;


CREATE OR REPLACE FUNCTION 
msar.add_time_to_vector(point_ point, time_ TIME) RETURNS point as $$/*
Add the given time, converted to a vector on unit circle, to the vector given in first argument.

We add a time to a point by
- converting the time to a point on the unit circle.
- adding that point to the point given in the first argument.

Args:
  point_: A point representing a vector.
  time_: A time that is converted to a vector and added to the vector represented by point_.

Returns:
  point that stores the resultant vector after the addition.
*/
WITH t(degrees) AS (SELECT msar.time_to_degrees(time_))
SELECT point_ + point(sind(degrees), cosd(degrees)) FROM t;
$$ LANGUAGE SQL STRICT;


CREATE OR REPLACE FUNCTION 
msar.point_to_time(point_ point) RETURNS TIME AS $$/*
Convert a point to degrees and then to time.

Point is converted to time by:
- first converting to degrees by calculating the inverse tangent of the point
- then converting the degrees to the time.
- If the point is on or very near the origin, we return null.

Args:
  point_: A point that represents a vector

Returns:
  time corresponding to the vector represented by point_.
*/
SELECT CASE
  /*
  When both sine and cosine are zero, the answer should be null.

  To avoid garbage output caused by the precision errors of the float
  variables, it's better to extend the condition to:
  Output is null when the distance of the point from the origin is less than
  a certain epsilon. (Epsilon here is 1e-10)
  */
  WHEN point_ <-> point(0,0) < 1e-10 THEN NULL
  ELSE msar.degrees_to_time(atan2d(point_[0],point_[1]))
END;
$$ LANGUAGE SQL;


CREATE OR REPLACE AGGREGATE
msar.peak_time (TIME)/*
Takes a column of type time and calculates the peak time.

State value:
  - state value is a variable of type point which stores the running vector
    sum of the points represented by the time variables.

Steps:
  - Convert time to degrees.
  - Calculate sine and cosine of the degrees.
  - Add this to the state point to update the running sum.
  - Calculate the inverse tangent of the state point.
  - Convert the result to time, which is the peak time.

Refer to the following PR to learn more.
Link: https://github.com/centerofci/mathesar/pull/2981
*/
(
  sfunc = msar.add_time_to_vector,
  stype = point,
  finalfunc = msar.point_to_time,
  initcond = '(0,0)'
);


CREATE OR REPLACE FUNCTION
msar.time_since_start_of_week_to_degrees(timestamp_ TIMESTAMP) RETURNS DOUBLE PRECISION AS $$/*
Convert timestamp to degrees (considering seconds passed since the start of week).

To get the fraction of 7 * 86400 seconds passed, we divide time_ by 7 * 86400 and then to get
the equivalent fraction of 360°, we multiply by 360, which is equivalent to divide by 1680.

Examples:
  2023-05-02 00:00:00 => 102.85714285714286
  2023-07-12 06:00:00 => 167.14285714285714
*/
SELECT (EXTRACT(DOW FROM timestamp_::date) * 86400 + EXTRACT(EPOCH FROM timestamp_::time))::double precision / 1680;    
$$ LANGUAGE SQL;


CREATE OR REPLACE FUNCTION 
msar.degrees_to_seconds_passed_since_start_of_week(degrees DOUBLE PRECISION) RETURNS DOUBLE PRECISION AS $$/*
Convert degrees to seconds passed since the start of week.

To get the fraction of 360°, we divide degrees value by 360 and then to get the equivalent 
fractions of 7 * 86400 seconds, we multiply by 7 * 86400, which is equivalent to multiply
by 1680.

Examples:
     0 =>      0
   120 => 201600
   240 => 403200
  -120 => 403200
*/
SELECT ((degrees::numeric % 360 + 360) %360)::double precision * 1680;
$$ LANGUAGE SQL;


CREATE OR REPLACE FUNCTION 
msar.day_of_week_int_to_string(day_of_week INT) RETURNS TEXT AS $$/*
Convert integer representing day of week to string

Examples:
   0 => Sunday
   1 => Monday
   and so on....
*/
SELECT CASE
  WHEN day_of_week = 0 THEN 'Sunday'
  WHEN day_of_week = 1 THEN 'Monday'
  WHEN day_of_week = 2 THEN 'Tuesday'
  WHEN day_of_week = 3 THEN 'Wednesday'
  WHEN day_of_week = 4 THEN 'Thursday'
  WHEN day_of_week = 5 THEN 'Friday'
  WHEN day_of_week = 6 THEN 'Saturday'
END;
$$ LANGUAGE SQL;


CREATE OR REPLACE FUNCTION 
msar.add_time_of_week_to_vector(point_ point, timestamp_ TIMESTAMP) RETURNS point as $$/*
Add the given timestamp, converted to a vector on unit circle, to the vector in the first argument.

We add a timestamp to a point by
- calculating the seconds passed since the start of week and converting the result to degrees.
- converting the degrees to a point on the unit circle.
- adding that point to the point given in the first argument.

Args:
  point_: A point representing a vector.
  timestamp_: A timestamp_ that is converted to a vector and added to the vector represented by point_.

Returns:
  point that stores the resultant vector after the addition.
*/
WITH t(degrees) AS (SELECT msar.time_since_start_of_week_to_degrees(timestamp_))
SELECT point_ + point(sind(degrees), cosd(degrees)) FROM t;
$$ LANGUAGE SQL STRICT;


CREATE OR REPLACE FUNCTION 
msar.point_to_day_of_week(point_ point) RETURNS text AS $$/*
Convert a point to degrees and then to a day of week.

Point is converted to day_of_week by:
- first converting to degrees by calculating the inverse tangent of the point.
- then converting the degrees to the seconds passed since the start of week.
- then extracting the day of week from seconds by dividing by 86400 and then taking floor
- If the point is on or very near to the origin, we return null.

Args:
  point_: A point that represents a vector.

Returns:
  a day of week corresponding to the vector represented by point_.
*/
SELECT CASE
  /*
  When both sine and cosine are zero, the answer should be null.

  To avoid garbage output caused by the precision errors of the float
  variables, it's better to extend the condition to:
  Output is null when the distance of the point from the origin is less than
  a certain epsilon. (Epsilon here is 1e-10)
  */
  WHEN point_ <-> point(0,0) < 1e-10 THEN NULL
  ELSE msar.day_of_week_int_to_string(floor(msar.degrees_to_seconds_passed_since_start_of_week(atan2d(point_[0],point_[1])) / (86400))::int)
END;
$$ LANGUAGE SQL;


CREATE OR REPLACE AGGREGATE 
msar.peak_day_of_week (TIMESTAMP)/*
Takes a column of type timestamp and calculates the peak day of week.

State value:
  - state value is a variable of type point which stores the running vector
    sum of the points represented by the timestamp variables.

Steps:
  - Convert timestamp to seconds passed since the start of week.
  - convert the result to degrees.
  - Calculate sine and cosine of the degrees.
  - Add this to the state point to update the running sum.
  - Calculate the inverse tangent of the state point.
  - Convert the result a day of week which is the peak day of week.

Refer to the following PR to learn more.
Link: https://github.com/centerofci/mathesar/pull/3004
*/
(
  sfunc = msar.add_time_of_week_to_vector,
  stype = point,
  finalfunc = msar.point_to_day_of_week,
  initcond = '(0,0)'
);



CREATE OR REPLACE FUNCTION month_to_degrees(_date DATE)
	returns DOUBLE PRECISION AS $$
    SELECT ((EXTRACT(MONTH FROM _date) - 1)::double precision) * 360 / 12;    
$$ LANGUAGE SQL;


CREATE OR REPLACE FUNCTION degrees_to_month(degrees DOUBLE PRECISION)
	returns INT AS $$
    SELECT ((ROUND(degrees * 12 / 360)::int) % 12) + 1;
$$ LANGUAGE SQL;


CREATE OR REPLACE FUNCTION month_to_string(_month INT)
    RETURNS TEXT AS $$
    SELECT CASE
        WHEN _month = 1 THEN 'January'
        WHEN _month = 2 THEN 'February'
        WHEN _month = 3 THEN 'March'
        WHEN _month = 4 THEN 'April'
        WHEN _month = 5 THEN 'May'
        WHEN _month = 6 THEN 'June'
        WHEN _month = 7 THEN 'July'
        WHEN _month = 8 THEN 'August'
        WHEN _month = 9 THEN 'September'
        WHEN _month = 10 THEN 'October'
        WHEN _month = 11 THEN 'November'
        WHEN _month = 12 THEN 'December'
    END;
$$ LANGUAGE SQL;


CREATE OR REPLACE FUNCTION accum_month(state DOUBLE PRECISION[], _date DATE)
	RETURNS DOUBLE PRECISION[] as $$
	SELECT ARRAY[state[1] + SIND(month_to_degrees(_date)), state[2] + COSD(month_to_degrees(_date))];
$$ LANGUAGE SQL STRICT;


CREATE OR REPLACE FUNCTION final_func_peak_month(state DOUBLE PRECISION[])
    RETURNS TEXT AS $$
	SELECT CASE
        WHEN @state[1] + @state[2] < 1e-10 THEN NULL
        ELSE month_to_string(
                degrees_to_month(
                    CASE
                        WHEN ATAN2D(state[1], state[2]) < 0 THEN ATAN2D(state[1], state[2]) + 360
                        ELSE ATAN2D(state[1], state[2])
                    END
                )
        )
    END;
$$ LANGUAGE SQL;


CREATE OR REPLACE AGGREGATE peak_month (DATE)
(
    sfunc = accum_month,
    stype = DOUBLE PRECISION[],
    finalfunc = final_func_peak_month,
    initcond = '{0,0}'
);