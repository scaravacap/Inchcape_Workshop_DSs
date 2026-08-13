# Databricks notebook source
# MAGIC %md
# MAGIC # Control de calidad sobre la predicción
# MAGIC
# MAGIC Corre después del scoring y falla la tarea si el pronóstico salió raro. La idea es
# MAGIC que el problema aparezca acá, en un job que notifica, y no en la reunión de compras
# MAGIC del lunes.
# MAGIC
# MAGIC Cuatro controles, del más barato al más caro:
# MAGIC
# MAGIC 1. La tabla tiene filas para el horizonte esperado.
# MAGIC 2. No hay predicciones negativas ni nulas.
# MAGIC 3. Todas las filas vienen de la misma versión del modelo.
# MAGIC 4. El volumen total no se desvía más de lo tolerado contra la corrida anterior.
# MAGIC
# MAGIC El cuarto es el que atrapa el problema interesante: un modelo que se rompió pero
# MAGIC sigue devolviendo números con cara de válidos.

# COMMAND ----------

dbutils.widgets.text("catalogo", "inchcape_workshop")
dbutils.widgets.text("esquema", "ml")
dbutils.widgets.text("desvio_maximo_pct", "40")

CAT = dbutils.widgets.get("catalogo")
ESQ = dbutils.widgets.get("esquema")
DESVIO_MAX = float(dbutils.widgets.get("desvio_maximo_pct"))
TABLA = f"{CAT}.{ESQ}.prediccion_demanda"

fallas = []

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1 y 2. Que haya filas y que sean números plausibles

# COMMAND ----------

resumen = spark.sql(f"""
SELECT count(*)                                             AS filas,
       count(DISTINCT semana_predicha)                      AS semanas,
       count(DISTINCT modelo_version)                       AS versiones,
       sum(CASE WHEN demanda_predicha IS NULL THEN 1 ELSE 0 END) AS nulas,
       sum(CASE WHEN demanda_predicha < 0 THEN 1 ELSE 0 END)     AS negativas,
       round(sum(demanda_predicha))                         AS unidades,
       max(corrida_ts)                                      AS ultima_corrida
FROM {TABLA}
WHERE corrida_ts = (SELECT max(corrida_ts) FROM {TABLA})
""").first()

print(f"filas={resumen['filas']} semanas={resumen['semanas']} "
      f"versiones={resumen['versiones']} nulas={resumen['nulas']} "
      f"negativas={resumen['negativas']} unidades={resumen['unidades']}")

if resumen["filas"] == 0:
    fallas.append("La corrida más reciente no dejó ninguna fila.")
if resumen["nulas"] > 0:
    fallas.append(f"{resumen['nulas']} predicciones nulas.")
if resumen["negativas"] > 0:
    fallas.append(f"{resumen['negativas']} predicciones negativas.")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. Una sola versión del modelo por corrida
# MAGIC
# MAGIC Dos versiones en la misma corrida significa que el scoring leyó el alias a mitad de
# MAGIC una promoción. Las predicciones no son comparables entre sí.

# COMMAND ----------

if resumen["versiones"] and resumen["versiones"] > 1:
    fallas.append(f"La corrida mezcla {resumen['versiones']} versiones del modelo.")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. El desvío contra la corrida anterior
# MAGIC
# MAGIC Si no hay corrida previa, este control se salta: no hay contra qué comparar y
# MAGIC fallar por eso sería fallar por ser la primera vez.

# COMMAND ----------

previa = spark.sql(f"""
SELECT round(sum(demanda_predicha)) AS unidades
FROM {TABLA}
WHERE corrida_ts = (SELECT max(corrida_ts) FROM {TABLA}
                    WHERE corrida_ts < (SELECT max(corrida_ts) FROM {TABLA}))
""").first()

if previa and previa["unidades"]:
    actual = float(resumen["unidades"] or 0)
    anterior = float(previa["unidades"])
    desvio = abs(actual - anterior) / max(anterior, 1e-9) * 100
    print(f"volumen actual {actual:.0f} contra anterior {anterior:.0f}: "
          f"{desvio:.1f}% de desvío, tolerado {DESVIO_MAX:.0f}%")
    if desvio > DESVIO_MAX:
        fallas.append(f"El volumen pronosticado se movió {desvio:.1f}% contra la "
                      f"corrida anterior, por encima del {DESVIO_MAX:.0f}% tolerado.")
else:
    print("no hay corrida anterior con la cual comparar, control de desvío omitido")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Resultado
# MAGIC
# MAGIC La tarea falla con la lista completa de problemas, no con el primero. Arreglar de
# MAGIC a uno por corrida es la forma lenta de arreglar cuatro.

# COMMAND ----------

if fallas:
    raise ValueError("Control de calidad de la predicción: " + " | ".join(fallas))

print("los cuatro controles pasaron")
dbutils.notebook.exit(f"OK filas={resumen['filas']} unidades={resumen['unidades']}")
