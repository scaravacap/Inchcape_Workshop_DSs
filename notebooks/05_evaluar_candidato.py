# Databricks notebook source
# MAGIC %md
# MAGIC # Evaluar la versión candidata contra el campeón
# MAGIC
# MAGIC Última tarea del job de reentrenamiento. Compara la versión recién registrada
# MAGIC contra la que hoy tiene el alias `@campeon` y deja el veredicto escrito.
# MAGIC
# MAGIC **No promueve nada.** El alias lo mueve una persona. Automatizar la promoción es
# MAGIC automatizar una decisión de negocio, y el día que el modelo se degrade por un
# MAGIC cambio en los datos, nadie va a haber mirado.

# COMMAND ----------

# MAGIC %pip install --upgrade "mlflow[databricks]" "scikit-learn==1.5.2" --quiet
# MAGIC %restart_python

# COMMAND ----------

dbutils.widgets.text("catalogo", "inchcape_workshop")
dbutils.widgets.text("esquema", "ml")
dbutils.widgets.text("modelo", "demanda_repuestos")
dbutils.widgets.text("mejora_minima_pct", "5")

CAT = dbutils.widgets.get("catalogo")
ESQ = dbutils.widgets.get("esquema")
MEJORA_MIN = float(dbutils.widgets.get("mejora_minima_pct"))
MODELO = f"{CAT}.{ESQ}.{dbutils.widgets.get('modelo')}"

import mlflow

mlflow.set_registry_uri("databricks-uc")

from mlflow.tracking import MlflowClient

cli = MlflowClient()

# COMMAND ----------

# MAGIC %md
# MAGIC ## Quién es quién
# MAGIC
# MAGIC El candidato es la versión más alta registrada. El campeón es el que tiene el
# MAGIC alias. Si todavía no hay alias, el candidato se compara solo contra la línea base.

# COMMAND ----------

versiones = sorted((int(v.version) for v in cli.search_model_versions(f"name='{MODELO}'")))
candidato = versiones[-1]

try:
    campeon = int(cli.get_model_version_by_alias(MODELO, "campeon").version)
except Exception:
    campeon = None

print(f"candidato: versión {candidato}")
print(f"campeón actual: {'versión ' + str(campeon) if campeon else 'todavía no hay'}")


def mae_de(version):
    """El MAE que quedó registrado en la corrida que produjo esa versión."""
    mv = cli.get_model_version(MODELO, str(version))
    if not mv.run_id:
        return None
    corrida = cli.get_run(mv.run_id)
    return corrida.data.metrics.get("mae")


mae_candidato = mae_de(candidato)
mae_campeon = mae_de(campeon) if campeon else None
print(f"MAE candidato: {mae_candidato}")
print(f"MAE campeón: {mae_campeon}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## El veredicto
# MAGIC
# MAGIC La mejora tiene que superar un umbral, no solo ser positiva. Un modelo que mejora
# MAGIC medio punto no compensa el riesgo de cambiar lo que ya funciona.

# COMMAND ----------

if mae_candidato is None:
    veredicto = "SIN_METRICA"
    detalle = (f"La versión {candidato} no tiene MAE registrado en su corrida. "
               f"Revisá que el entrenamiento haya hecho log_metric('mae').")
elif campeon is None:
    veredicto = "PROMOVER"
    detalle = (f"No hay campeón. La versión {candidato} es la primera candidata, "
               f"con MAE {mae_candidato:.3f}.")
elif candidato == campeon:
    veredicto = "SIN_CAMBIO"
    detalle = f"La versión {candidato} ya es el campeón. No se entrenó nada nuevo."
elif mae_campeon is None:
    veredicto = "REVISAR"
    detalle = (f"El campeón, versión {campeon}, no tiene MAE registrado. "
               f"La comparación automática no es posible.")
else:
    mejora = (mae_campeon - mae_candidato) / mae_campeon * 100
    if mejora >= MEJORA_MIN:
        veredicto = "PROMOVER"
        detalle = (f"La versión {candidato} mejora {mejora:.1f}% el MAE del campeón "
                   f"(versión {campeon}): {mae_candidato:.3f} contra {mae_campeon:.3f}. "
                   f"Supera el umbral de {MEJORA_MIN:.0f}%.")
    else:
        veredicto = "MANTENER"
        detalle = (f"La versión {candidato} mueve el MAE {mejora:+.1f}% contra el "
                   f"campeón (versión {campeon}): {mae_candidato:.3f} contra "
                   f"{mae_campeon:.3f}. No alcanza el umbral de {MEJORA_MIN:.0f}%.")

print(f"{veredicto}: {detalle}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Dejarlo escrito donde alguien lo lea
# MAGIC
# MAGIC El veredicto va en la descripción de la versión. Quien abra el modelo en el Catalog
# MAGIC Explorer dentro de tres meses va a encontrar ahí por qué se promovió o por qué no.

# COMMAND ----------

mv = cli.get_model_version(MODELO, str(candidato))
descripcion = (mv.description or "").split("\n\nVeredicto:")[0]
cli.update_model_version(MODELO, str(candidato),
                         description=f"{descripcion}\n\nVeredicto: {veredicto}. {detalle}")

if veredicto == "PROMOVER":
    print(f"Para promoverla, alguien tiene que correr:\n"
          f"  MlflowClient().set_registered_model_alias("
          f"'{MODELO}', 'campeon', '{candidato}')")

dbutils.notebook.exit(f"{veredicto}: {detalle}")
