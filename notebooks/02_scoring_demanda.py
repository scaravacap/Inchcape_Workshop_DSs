# Databricks notebook source
# MAGIC %md
# MAGIC # Scoring semanal de demanda
# MAGIC
# MAGIC Carga el modelo por **alias**, no por número de versión, y escribe el pronóstico
# MAGIC en `prediccion_demanda`. Promover una versión nueva a `@campeon` no requiere tocar
# MAGIC este notebook ni el job.
# MAGIC
# MAGIC La versión de scikit-learn va fijada y tiene que ser la misma con la que se
# MAGIC entrenó. Un job puede arrancar con un runtime distinto al de la sesión interactiva,
# MAGIC y ahí el modelo no carga.

# COMMAND ----------

# MAGIC %pip install --upgrade "mlflow[databricks]" "scikit-learn==1.5.2" --quiet
# MAGIC %restart_python

# COMMAND ----------

dbutils.widgets.text("catalogo", "inchcape_workshop")
dbutils.widgets.text("esquema", "ml")
dbutils.widgets.text("modelo", "demanda_repuestos")
dbutils.widgets.text("alias", "campeon")
dbutils.widgets.text("horizonte_semanas", "4")

CAT = dbutils.widgets.get("catalogo")
ESQ = dbutils.widgets.get("esquema")
ALIAS = dbutils.widgets.get("alias")
HORIZONTE = int(dbutils.widgets.get("horizonte_semanas"))
MODELO = f"{CAT}.{ESQ}.{dbutils.widgets.get('modelo')}"

import mlflow

mlflow.set_registry_uri("databricks-uc")

import pandas as pd
from mlflow.tracking import MlflowClient

cli = MlflowClient()
version = cli.get_model_version_by_alias(MODELO, ALIAS).version
modelo = mlflow.pyfunc.load_model(f"models:/{MODELO}@{ALIAS}")
print(f"modelo cargado por alias {ALIAS}, versión {version}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## El horizonte se construye hacia adelante
# MAGIC
# MAGIC Para la semana 2, el rezago de una semana es la predicción de la semana 1, no un
# MAGIC dato real. Si se usara el mismo vector de variables para las cuatro semanas, el
# MAGIC pronóstico sería el mismo número repetido.

# COMMAND ----------

pdf = spark.table(f"{CAT}.{ESQ}.features_demanda").toPandas()
pdf["semana"] = pd.to_datetime(pdf["semana"])
ultima = pdf["semana"].max()
print(f"última semana con datos: {ultima.date()}")

NUM = ["lag_1", "lag_2", "lag_4", "lag_13", "media_4", "desv_4", "media_13",
       "tasa_quiebre_prev", "bahias"]
CATC = ["semana_del_anio", "mes", "pais", "tipo_punto", "familia"]
FEAT = NUM + CATC

hist = (pdf.sort_values("semana")
          .groupby(["dealer_id", "familia"])["demanda_unidades"]
          .apply(list).to_dict())
estatico = (pdf[pdf["semana"] == ultima]
            .set_index(["dealer_id", "familia"])[["pais", "tipo_punto", "bahias",
                                                  "tasa_quiebre_prev"]]
            .to_dict("index"))
print(f"{len(estatico)} combinaciones de punto de red y familia a predecir")

filas = []
serie = {k: list(v) for k, v in hist.items()}
for h in range(1, HORIZONTE + 1):
    semana_obj = ultima + pd.Timedelta(weeks=h)
    lote, llaves = [], []
    for (dealer, fam), est in estatico.items():
        s = serie.get((dealer, fam), [])
        if len(s) < 13:
            continue
        lote.append({
            "lag_1": s[-1], "lag_2": s[-2], "lag_4": s[-4], "lag_13": s[-13],
            "media_4": sum(s[-4:]) / 4,
            "desv_4": pd.Series(s[-4:]).std(ddof=1),
            "media_13": sum(s[-13:]) / 13,
            "tasa_quiebre_prev": est["tasa_quiebre_prev"],
            "bahias": est["bahias"],
            "semana_del_anio": f"{semana_obj.isocalendar().week:02d}",
            "mes": f"{semana_obj.month:02d}",
            "pais": est["pais"], "tipo_punto": est["tipo_punto"], "familia": fam,
        })
        llaves.append((dealer, fam))
    X = pd.DataFrame(lote)
    X["desv_4"] = X["desv_4"].fillna(0.0)
    # La firma del modelo fija int32 para bahias y pandas produce int64 por defecto.
    X["bahias"] = X["bahias"].astype("int32")
    preds = modelo.predict(X[FEAT])
    for (dealer, fam), p in zip(llaves, preds):
        p = float(max(p, 0.0))
        serie[(dealer, fam)].append(p)
        filas.append({"semana_predicha": semana_obj.date(), "dealer_id": dealer,
                      "familia": fam, "demanda_predicha": round(p, 2),
                      "modelo_version": str(version)})

pred_pdf = pd.DataFrame(filas)
print(f"{len(pred_pdf)} predicciones, de {pred_pdf['semana_predicha'].min()} "
      f"a {pred_pdf['semana_predicha'].max()}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## La escritura es idempotente
# MAGIC
# MAGIC Borra el horizonte que va a reescribir y vuelve a insertar. Correr el job dos veces
# MAGIC el mismo lunes deja la tabla igual, no duplicada.

# COMMAND ----------

from pyspark.sql import functions as F

sdf = (spark.createDataFrame(pred_pdf)
       .withColumn("semana_predicha", F.col("semana_predicha").cast("date"))
       .withColumn("corrida_ts", F.current_timestamp()))

spark.sql(f"""
CREATE TABLE IF NOT EXISTS {CAT}.{ESQ}.prediccion_demanda (
  semana_predicha  DATE      COMMENT 'Lunes de la semana pronosticada.',
  dealer_id        STRING    COMMENT 'Punto de red.',
  familia          STRING    COMMENT 'Familia de repuesto.',
  demanda_predicha DOUBLE    COMMENT 'Unidades pronosticadas para esa semana.',
  modelo_version   STRING    COMMENT 'Version del modelo que produjo la fila.',
  corrida_ts       TIMESTAMP COMMENT 'Momento de la corrida de scoring.')
COMMENT 'Pronostico semanal de demanda de repuestos por punto de red y familia, con horizonte de cuatro semanas. Se refresca semanal. Error esperado: MAE cercano a 17 unidades.'
""")

sdf.createOrReplaceTempView("_nuevas")
spark.sql(f"""
  DELETE FROM {CAT}.{ESQ}.prediccion_demanda
  WHERE semana_predicha IN (SELECT DISTINCT semana_predicha FROM _nuevas)
""")
spark.sql(f"INSERT INTO {CAT}.{ESQ}.prediccion_demanda SELECT * FROM _nuevas")

spark.sql(f"""ALTER TABLE {CAT}.{ESQ}.prediccion_demanda SET TAGS (
  'dominio'='posventa','tipo'='prediccion','modelo'='demanda_repuestos',
  'dueño'='data-science-andina','refresco'='semanal')""")

n = spark.table(f"{CAT}.{ESQ}.prediccion_demanda").count()
print(f"prediccion_demanda: {n} filas")

# COMMAND ----------

# MAGIC %md
# MAGIC ## La vista que abre compras
# MAGIC
# MAGIC El criterio es que el inventario quede **por debajo del punto de reorden** después
# MAGIC de servir la demanda pronosticada. "La demanda supera el stock" avisa cuando ya es
# MAGIC tarde.

# COMMAND ----------

spark.sql(f"""
CREATE OR REPLACE VIEW {CAT}.{ESQ}.vw_riesgo_quiebre
COMMENT 'Combinaciones de punto de red y familia donde el inventario cae por debajo del punto de reorden despues de servir la demanda pronosticada de las proximas cuatro semanas. Es la lista de compra sugerida, ordenada por cuanto se hunde bajo el punto de reorden.'
AS
WITH inv AS (
  SELECT k.dealer_id, m.familia,
         sum(k.stock_unidades) AS stock_actual,
         sum(k.punto_reorden)  AS punto_reorden
  FROM {CAT}.ops.fact_stock k
  JOIN {CAT}.ops.dim_material m ON m.material_id = k.material_id
  WHERE k.fecha_snapshot = (SELECT max(fecha_snapshot) FROM {CAT}.ops.fact_stock)
  GROUP BY 1, 2),
dem AS (
  SELECT dealer_id, familia,
         sum(demanda_predicha) AS demanda_4_semanas,
         max(modelo_version)   AS modelo_version
  FROM {CAT}.{ESQ}.prediccion_demanda
  GROUP BY 1, 2)
SELECT d.dealer_id, l.dealer_nombre, l.pais, l.ciudad, d.familia,
       round(d.demanda_4_semanas, 1)                  AS demanda_4_semanas,
       i.stock_actual,
       i.punto_reorden,
       round(i.stock_actual - d.demanda_4_semanas, 1) AS stock_proyectado,
       round(i.punto_reorden - (i.stock_actual - d.demanda_4_semanas), 1) AS brecha_vs_reorden,
       d.modelo_version
FROM dem d
JOIN inv i ON i.dealer_id = d.dealer_id AND i.familia = d.familia
JOIN {CAT}.ops.dim_dealer l ON l.dealer_id = d.dealer_id
WHERE i.stock_actual - d.demanda_4_semanas < i.punto_reorden
ORDER BY brecha_vs_reorden DESC
""")

riesgo = spark.table(f"{CAT}.{ESQ}.vw_riesgo_quiebre").count()
print(f"vw_riesgo_quiebre: {riesgo} combinaciones en riesgo")

dbutils.notebook.exit(f"OK filas={n} riesgo={riesgo} version={version}")
