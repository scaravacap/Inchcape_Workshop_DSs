# Databricks notebook source
# MAGIC %md
# MAGIC # Feature table de demanda semanal
# MAGIC
# MAGIC Construye `<catalogo>.<esquema>.features_demanda`: una fila por punto de red,
# MAGIC familia y semana, con los rezagos y las ventanas móviles que alimentan el modelo.
# MAGIC
# MAGIC Es la primera tarea del job de reentrenamiento del bundle, y también corre sola
# MAGIC desde el notebook. Los parámetros llegan como widgets; los valores por defecto son
# MAGIC los del taller.
# MAGIC
# MAGIC **Todas las ventanas son estrictamente anteriores a la semana de la fila.** Esa es
# MAGIC la regla que evita la fuga de información, y por eso cada `ROWS BETWEEN` termina en
# MAGIC `1 PRECEDING` y nunca en `CURRENT ROW`.

# COMMAND ----------

dbutils.widgets.text("catalogo", "inchcape_workshop")
dbutils.widgets.text("esquema", "ml")

CAT = dbutils.widgets.get("catalogo")
ESQ = dbutils.widgets.get("esquema")
TABLA = f"{CAT}.{ESQ}.features_demanda"

spark.sql(f"CREATE SCHEMA IF NOT EXISTS {CAT}.{ESQ}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## El esquema
# MAGIC
# MAGIC La clave primaria declarada es lo que convierte una tabla Delta en una feature
# MAGIC table de Unity Catalog. Las columnas de la clave van en `NOT NULL`.

# COMMAND ----------

spark.sql(f"DROP TABLE IF EXISTS {TABLA}")
spark.sql(f"""
CREATE TABLE {TABLA} (
  dealer_id            STRING  NOT NULL COMMENT 'Punto de red. Parte de la llave.',
  familia              STRING  NOT NULL COMMENT 'Familia de repuesto. Parte de la llave.',
  semana               DATE    NOT NULL COMMENT 'Lunes de la semana ISO. Parte de la llave.',
  demanda_unidades     DOUBLE  COMMENT 'Objetivo: unidades vendidas en la semana.',
  lag_1                DOUBLE  COMMENT 'Demanda de la semana anterior.',
  lag_2                DOUBLE  COMMENT 'Demanda de dos semanas antes.',
  lag_4                DOUBLE  COMMENT 'Demanda de cuatro semanas antes.',
  lag_13               DOUBLE  COMMENT 'Demanda de trece semanas antes, componente anual.',
  media_4              DOUBLE  COMMENT 'Media de las 4 semanas previas, sin incluir la actual.',
  desv_4               DOUBLE  COMMENT 'Desviacion de las 4 semanas previas.',
  media_13             DOUBLE  COMMENT 'Media de las 13 semanas previas.',
  tasa_quiebre_prev    DOUBLE  COMMENT 'Fraccion en quiebre de stock la semana anterior.',
  semana_del_anio      STRING  COMMENT 'Semana ISO como categorica, no como entero.',
  mes                  STRING  COMMENT 'Mes como categorica.',
  pais                 STRING  COMMENT 'Pais del punto de red.',
  tipo_punto           STRING  COMMENT 'Tipo de punto de red.',
  bahias               INT     COMMENT 'Bahias de taller del punto.',
  es_periodo_incidente BOOLEAN COMMENT 'Verdadero entre 2026-03-02 y 2026-04-17.',
  CONSTRAINT features_demanda_pk PRIMARY KEY (dealer_id, familia, semana)
)
COMMENT 'Feature table de demanda semanal de repuestos por punto de red y familia. Todas las ventanas son estrictamente anteriores a la semana de la fila.'
""")

# COMMAND ----------

# MAGIC %md
# MAGIC ## La carga
# MAGIC
# MAGIC Cada ventana lleva su `OVER (PARTITION BY ... ORDER BY ...)` completo. Spark no
# MAGIC deja extender una ventana nombrada con `ROWS BETWEEN`, así que la forma corta con
# MAGIC `WINDOW w AS (...)` falla en el análisis.

# COMMAND ----------

spark.sql(f"""
INSERT INTO {TABLA}
WITH ventas AS (
  SELECT s.dealer_id, m.familia, date_trunc('week', s.fecha)::date AS semana,
         sum(s.cantidad)::double AS demanda_unidades
  FROM {CAT}.ops.fact_parts_sales s
  JOIN {CAT}.ops.dim_material m ON m.material_id = s.material_id
  GROUP BY 1, 2, 3),
quiebre AS (
  SELECT k.dealer_id, m.familia, date_trunc('week', k.fecha_snapshot)::date AS semana,
         avg(CASE WHEN k.en_quiebre THEN 1.0 ELSE 0.0 END) AS tasa_quiebre
  FROM {CAT}.ops.fact_stock k
  JOIN {CAT}.ops.dim_material m ON m.material_id = k.material_id
  GROUP BY 1, 2, 3),
base AS (
  SELECT v.*, q.tasa_quiebre FROM ventas v
  LEFT JOIN quiebre q ON q.dealer_id = v.dealer_id AND q.familia = v.familia AND q.semana = v.semana),
calc AS (
  SELECT b.dealer_id, b.familia, b.semana, b.demanda_unidades,
    lag(b.demanda_unidades, 1)  OVER (PARTITION BY b.dealer_id, b.familia ORDER BY b.semana) AS lag_1,
    lag(b.demanda_unidades, 2)  OVER (PARTITION BY b.dealer_id, b.familia ORDER BY b.semana) AS lag_2,
    lag(b.demanda_unidades, 4)  OVER (PARTITION BY b.dealer_id, b.familia ORDER BY b.semana) AS lag_4,
    lag(b.demanda_unidades, 13) OVER (PARTITION BY b.dealer_id, b.familia ORDER BY b.semana) AS lag_13,
    avg(b.demanda_unidades)     OVER (PARTITION BY b.dealer_id, b.familia ORDER BY b.semana
                                      ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS media_4,
    stddev(b.demanda_unidades)  OVER (PARTITION BY b.dealer_id, b.familia ORDER BY b.semana
                                      ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS desv_4,
    avg(b.demanda_unidades)     OVER (PARTITION BY b.dealer_id, b.familia ORDER BY b.semana
                                      ROWS BETWEEN 13 PRECEDING AND 1 PRECEDING) AS media_13,
    lag(b.tasa_quiebre, 1)      OVER (PARTITION BY b.dealer_id, b.familia ORDER BY b.semana) AS tasa_quiebre_prev
  FROM base b)
SELECT c.dealer_id, c.familia, c.semana, c.demanda_unidades,
       c.lag_1, c.lag_2, c.lag_4, c.lag_13,
       c.media_4, coalesce(c.desv_4, 0.0), c.media_13, coalesce(c.tasa_quiebre_prev, 0.0),
       lpad(weekofyear(c.semana)::string, 2, '0'), lpad(month(c.semana)::string, 2, '0'),
       d.pais, d.tipo_punto, d.bahias,
       c.semana BETWEEN DATE'2026-03-02' AND DATE'2026-04-17'
FROM calc c JOIN {CAT}.ops.dim_dealer d ON d.dealer_id = c.dealer_id
WHERE c.lag_13 IS NOT NULL AND c.media_13 IS NOT NULL
""")

spark.sql(f"""ALTER TABLE {TABLA} SET TAGS (
  'dominio'='posventa','capa'='feature','dueño'='data-science-andina','refresco'='semanal')""")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Control
# MAGIC
# MAGIC Si la tabla sale vacía, la tarea falla acá y no tres pasos después.

# COMMAND ----------

n = spark.table(TABLA).count()
rango = spark.sql(f"SELECT min(semana) a, max(semana) b FROM {TABLA}").first()
print(f"{TABLA}: {n} filas, de {rango['a']} a {rango['b']}")

if n == 0:
    raise ValueError(f"{TABLA} quedó vacía. Revisá que ops.fact_parts_sales tenga datos.")

dbutils.notebook.exit(f"OK {n} filas, {rango['a']} a {rango['b']}")
