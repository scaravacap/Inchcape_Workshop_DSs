# Databricks notebook source
# MAGIC %md
# MAGIC # Entrenamiento y registro del modelo de demanda
# MAGIC
# MAGIC Entrena sobre `features_demanda`, compara contra la línea base ingenua y registra
# MAGIC una versión nueva en Unity Catalog. **No promueve el alias `@campeon`**: esa
# MAGIC decisión queda en `05_evaluar_candidato`, y la toma una persona.
# MAGIC
# MAGIC Las dos líneas de instalación no son opcionales. La versión de MLflow del runtime
# MAGIC no puede subir artefactos a Unity Catalog, y la versión de scikit-learn va fijada
# MAGIC porque el modelo se serializa con la versión que lo entrena: si el job de scoring
# MAGIC arranca con otra, el modelo no carga.

# COMMAND ----------

# MAGIC %pip install --upgrade "mlflow[databricks]" "scikit-learn==1.5.2" --quiet
# MAGIC %restart_python

# COMMAND ----------

dbutils.widgets.text("catalogo", "inchcape_workshop")
dbutils.widgets.text("esquema", "ml")
dbutils.widgets.text("modelo", "demanda_repuestos")
dbutils.widgets.text("semanas_validacion", "10")

CAT = dbutils.widgets.get("catalogo")
ESQ = dbutils.widgets.get("esquema")
SEMANAS = int(dbutils.widgets.get("semanas_validacion"))
MODELO = f"{CAT}.{ESQ}.{dbutils.widgets.get('modelo')}"

import mlflow

# Antes de set_experiment y de cualquier log_model. Si va después, en serverless
# falla con CONFIG_NOT_AVAILABLE.
mlflow.set_registry_uri("databricks-uc")

# COMMAND ----------

import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.metrics import mean_absolute_error, mean_squared_error
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder

usuario = spark.sql("SELECT current_user()").first()[0]
mlflow.set_experiment(f"/Users/{usuario}/inchcape_demanda")

pdf = spark.table(f"{CAT}.{ESQ}.features_demanda").toPandas()
pdf["semana"] = pd.to_datetime(pdf["semana"])

# La partición es temporal, nunca aleatoria: validar con semanas futuras es la
# única forma de estimar el error que el modelo va a tener en producción.
corte = pdf["semana"].max() - pd.Timedelta(weeks=SEMANAS)
tr, va = pdf[pdf["semana"] <= corte], pdf[pdf["semana"] > corte]
print(f"corte {corte.date()}: train {len(tr)}, validación {len(va)}")

NUM = ["lag_1", "lag_2", "lag_4", "lag_13", "media_4", "desv_4", "media_13",
       "tasa_quiebre_prev", "bahias"]
CATC = ["semana_del_anio", "mes", "pais", "tipo_punto", "familia"]
FEAT = NUM + CATC


def mape_ponderado(y, p):
    import numpy as np

    y, p = np.asarray(y, float), np.asarray(p, float)
    return float(np.abs(y - p).sum() / max(np.abs(y).sum(), 1e-9) * 100)


# COMMAND ----------

# MAGIC %md
# MAGIC ## La línea base
# MAGIC
# MAGIC Predecir "lo mismo que la semana pasada". Un modelo que no le gana a esto no
# MAGIC justifica su costo de mantenimiento.

# COMMAND ----------

base_mae = mean_absolute_error(va["demanda_unidades"], va["lag_1"])
with mlflow.start_run(run_name="linea_base_semana_anterior"):
    mlflow.log_metric("mae", base_mae)
    mlflow.log_metric("mape_ponderado", mape_ponderado(va["demanda_unidades"], va["lag_1"]))
print(f"línea base MAE {base_mae:.3f}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## El modelo
# MAGIC
# MAGIC `sparse_output=False` en el encoder porque `HistGradientBoostingRegressor` no
# MAGIC acepta matriz dispersa, y `serialization_format="cloudpickle"` porque es el
# MAGIC formato que carga igual desde un notebook, desde un job y desde un endpoint.

# COMMAND ----------

pipe = Pipeline([
    ("prep", ColumnTransformer(
        [("cat", OneHotEncoder(handle_unknown="ignore", sparse_output=False), CATC)],
        remainder="passthrough")),
    ("gbt", HistGradientBoostingRegressor(learning_rate=0.1, max_iter=200, random_state=7)),
])

with mlflow.start_run(run_name="hgb_demanda") as run:
    pipe.fit(tr[FEAT], tr["demanda_unidades"])
    pred = pipe.predict(va[FEAT])
    mae = mean_absolute_error(va["demanda_unidades"], pred)
    rmse = mean_squared_error(va["demanda_unidades"], pred) ** 0.5
    mlflow.log_params({"learning_rate": 0.1, "max_iter": 200,
                       "semanas_validacion": SEMANAS})
    mlflow.log_metrics({"mae": mae, "rmse": rmse,
                        "mape_ponderado": mape_ponderado(va["demanda_unidades"], pred)})
    firma = mlflow.models.infer_signature(tr[FEAT], pipe.predict(tr[FEAT].head(5)))
    mlflow.sklearn.log_model(
        pipe, name="model", signature=firma,
        input_example=tr[FEAT].head(3),
        serialization_format="cloudpickle",
        registered_model_name=MODELO)

print(f"modelo MAE {mae:.3f} / RMSE {rmse:.3f}, línea base {base_mae:.3f}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## La descripción de la versión
# MAGIC
# MAGIC Qué datos usó, qué periodo cubre y contra qué línea base se midió. Dentro de seis
# MAGIC meses, esto es lo único que explica por qué esta versión existe.

# COMMAND ----------

from mlflow.tracking import MlflowClient

cli = MlflowClient()
version = max(int(v.version) for v in cli.search_model_versions(f"name='{MODELO}'"))
cli.update_model_version(MODELO, version, description=(
    f"HistGradientBoosting sobre features_demanda. Validación de {SEMANAS} semanas "
    f"hasta {pdf['semana'].max().date()}. MAE {mae:.2f} contra línea base {base_mae:.2f}."))

print(f"registrado {MODELO} versión {version}, sin promover")
dbutils.notebook.exit(f"OK version={version} mae={mae:.3f} base={base_mae:.3f}")
