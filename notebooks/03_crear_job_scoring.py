# Databricks notebook source
# MAGIC %md
# MAGIC # Crear el job de scoring con el SDK
# MAGIC
# MAGIC En Free Edition no se pueden desplegar Databricks Asset Bundles, así que el job
# MAGIC se crea con el SDK de Python desde este notebook. Es la misma operación que hace
# MAGIC `databricks bundle deploy` por debajo.
# MAGIC
# MAGIC El SDK ya viene en el runtime y se autentica solo dentro del notebook: no hay que
# MAGIC configurar tokens ni perfiles.
# MAGIC
# MAGIC **Antes de correr esto** necesitás el notebook de scoring del Paso 5 guardado en tu
# MAGIC workspace. Ajustá `NOTEBOOK_SCORING` con su ruta.

# COMMAND ----------

from databricks.sdk import WorkspaceClient
from databricks.sdk.service import jobs

w = WorkspaceClient()

NOMBRE_JOB = "inchcape_scoring_demanda"
NOTEBOOK_SCORING = "/Workspace/Users/{}/inchcape/02_scoring_demanda".format(
    w.current_user.me().user_name
)
CORREO = w.current_user.me().user_name

# COMMAND ----------

# MAGIC %md
# MAGIC ## La definición del job
# MAGIC
# MAGIC Tres decisiones que hay que mirar antes de crear:
# MAGIC
# MAGIC - **`pause_status="PAUSED"`**. El job nace pausado. Un job que arranca a correr solo
# MAGIC   en cuanto se crea es una forma rápida de gastar la cuota diaria.
# MAGIC - **Agenda semanal los lunes a las 6**. El scoring corre después del cierre de la
# MAGIC   semana, no durante.
# MAGIC - **`max_concurrent_runs=1`**. Dos corridas de scoring en paralelo escribirían la
# MAGIC   misma tabla al mismo tiempo.

# COMMAND ----------

tarea = jobs.Task(
    task_key="scoring",
    notebook_task=jobs.NotebookTask(notebook_path=NOTEBOOK_SCORING),
    timeout_seconds=1800,
)

agenda = jobs.CronSchedule(
    quartz_cron_expression="0 0 6 ? * MON",
    timezone_id="America/Bogota",
    pause_status=jobs.PauseStatus.PAUSED,
)

notificaciones = jobs.JobEmailNotifications(on_failure=[CORREO])

# COMMAND ----------

# MAGIC %md
# MAGIC ## Crear o actualizar
# MAGIC
# MAGIC Idempotente a propósito: si el job ya existe, lo actualiza. Correr esta celda dos
# MAGIC veces no te deja dos jobs con el mismo nombre.

# COMMAND ----------

existente = next((j for j in w.jobs.list(name=NOMBRE_JOB)), None)

if existente is None:
    creado = w.jobs.create(
        name=NOMBRE_JOB,
        tasks=[tarea],
        schedule=agenda,
        email_notifications=notificaciones,
        max_concurrent_runs=1,
    )
    job_id = creado.job_id
    print(f"Job creado: {job_id}")
else:
    job_id = existente.job_id
    w.jobs.reset(
        job_id=job_id,
        new_settings=jobs.JobSettings(
            name=NOMBRE_JOB,
            tasks=[tarea],
            schedule=agenda,
            email_notifications=notificaciones,
            max_concurrent_runs=1,
        ),
    )
    print(f"Job actualizado: {job_id}")

print(f"{w.config.host}/jobs/{job_id}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Dispararlo una vez a mano
# MAGIC
# MAGIC Está pausado, así que la agenda no lo va a correr. Esta celda lo dispara una vez
# MAGIC para verificar que funciona de punta a punta.

# COMMAND ----------

corrida = w.jobs.run_now(job_id=job_id)
print(f"Corrida disparada: {corrida.run_id}")
print(f"{w.config.host}/jobs/{job_id}/runs/{corrida.run_id}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Verificar el resultado
# MAGIC
# MAGIC Cuando la corrida termine en verde, esta consulta tiene que devolver las
# MAGIC predicciones de las próximas cuatro semanas, con la versión del modelo al lado.

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT modelo_version,
# MAGIC        min(semana_predicha) AS desde,
# MAGIC        max(semana_predicha) AS hasta,
# MAGIC        count(*) AS filas,
# MAGIC        round(sum(demanda_predicha)) AS unidades_predichas
# MAGIC FROM inchcape_workshop.ml.prediccion_demanda
# MAGIC GROUP BY modelo_version
# MAGIC ORDER BY modelo_version;
