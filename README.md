# Taller Inchcape: de la exploración al modelo en producción

Guía para el grupo de **Data Science**.
Workshop Inchcape, Medellín, agosto 2026.

Arrancás explorando por qué se rompió la operación de posventa en marzo, y
terminás con un modelo de pronóstico de demanda registrado en Unity Catalog, un
job de scoring que corre solo, y las predicciones publicadas como Data Product
para que el negocio las consuma sin pedirte nada.

Corre entero dentro del navegador, en una cuenta gratuita. Nada que instalar.

## Antes de empezar

**Necesitás una cuenta de Databricks Free Edition.** Se crea en dos minutos:

1. Entra a [databricks.com/learn/free-edition](https://www.databricks.com/learn/free-edition).
2. Elige **Sign up with Google** o **Sign up with Microsoft**, o registra tu correo
   y confirma el código de seis dígitos que llega al buzón.
3. Databricks crea tu workspace y te deja adentro. No pide tarjeta de crédito.

Free Edition tiene tres límites que cambian el ejercicio, y los digo de una vez
para que nadie pierda tiempo peleando con ellos:

- El cómputo es **serverless**. No hay GPU, así que el modelo del Paso 3 es de
  árboles y no una red neuronal. Para pronóstico tabular de demanda, esa es la
  elección correcta de todas formas.
- Hay una **cuota diaria de uso**. Alcanza de sobra, pero entrená con la grilla de
  hiperparámetros chica que viene en el prompt. La grilla grande la agotás en una
  corrida.
- **No hay acceso libre a internet** desde el cómputo, así que `pip install` de
  paquetes externos puede fallar. Todo el recorrido usa lo que ya viene en el
  runtime de ML: `mlflow`, `scikit-learn`, `pandas`, `pyspark`.

El **Paso 6 es la parte de CI/CD**, y ahí sí hay cosas que no se pueden ejecutar
en Free Edition. Los archivos están en este repositorio, se los muestro corriendo
en demo desde mi entorno, y se los llevan listos para su plataforma. No les voy a
pedir instalar nada en su máquina durante el taller.

## Paso 0. Traer el material y crear los datos

**Clona este repositorio dentro de tu workspace.**

1. En el menú de la izquierda, entra a **Workspace**.
2. Botón **Create**, luego **Git folder**.
3. Pega esta URL:

```
https://github.com/scaravacap/Inchcape_Workshop_DSs
```

4. Deja el proveedor en **GitHub** y confirma. Es un repositorio público, así que
   no te va a pedir usuario ni token.

**Corre el notebook de datos.**

Abre `notebooks/00_setup_datos.sql` y dale **Run all**. Tarda entre uno y tres
minutos. Es SQL puro: no instala nada ni sale a internet.

**Cómo sabés que funcionó:** la última celda te devuelve once tablas con estas
cantidades de filas.

| Tabla | Filas |
|---|---|
| ops.dim_dealer | 120 |
| ops.dim_material | 800 |
| ops.fact_parts_sales | 175.241 |
| ops.fact_stock | 499.200 |
| ops.fact_workorder | 60.000 |
| ops.fact_supply_incident | 40 |
| pmo.pmo_projects | 25 |
| pmo.pmo_milestones | 150 |
| pmo.pmo_budget | 300 |
| raw.sap_mara | 830 |
| raw.sap_vbap | 44.045 |

Si te salen exactamente esos números, tenés los mismos datos que todo el mundo en
la sala, y por lo tanto los mismos resultados.

**Ahora lee [HISTORIA.md](HISTORIA.md).** Son tres minutos. Un modelo de demanda
sin entender el incidente de marzo termina aprendiendo el incidente como si fuera
estacionalidad, y ese es justo el error que vamos a evitar en el Paso 2.

## Paso 1. Exploración: entender antes de modelar

**Objetivo:** cuantificar el incidente y decidir qué hacer con él antes de tocar
un modelo.

**Qué hacer:** abre un notebook nuevo, menú **Workspace**, **Create**,
**Notebook**. Lenguaje Python. Con Genie Code al lado, el panel que se abre con el
ícono de la chispa.

Los prompts están en [PROMPTS.md, sección 1](PROMPTS.md#1-exploración). El primero
te da la serie de demanda semanal y la marca del periodo del incidente. El
segundo, la descomposición del quiebre de stock por familia y proveedor.

**La decisión de este paso, y es la que importa:** el periodo del 2 de marzo al 17
de abril de 2026 es una anomalía de oferta, no de demanda. La venta cayó porque no
había repuesto, no porque nadie lo quisiera. Si lo dejás en el entrenamiento, el
modelo aprende que marzo es un mes flojo. Hay tres caminos:

1. **Excluir el periodo** del entrenamiento. Simple, y pierde seis semanas de datos.
2. **Marcarlo con una variable indicadora.** El modelo aprende que hubo un evento
   y no lo generaliza. Es el camino que vamos a tomar.
3. **Imputar la demanda no atendida** con la venta perdida estimada. Es el más
   correcto conceptualmente y el que necesita más supuestos.

Escribí en el notebook cuál elegiste y por qué. Eso es lo que un revisor va a leer
primero.

**Cómo sabés que funcionó:** tenés un gráfico donde el periodo del incidente se ve
marcado, y podés decir en una frase cuántas unidades de demanda cayeron y qué
fracción de eso fue falta de inventario y no falta de cliente.

## Paso 2. Las variables: donde se gana el modelo

**Objetivo:** construir la tabla de entrenamiento con grano semana por punto de red
por familia, y las variables que de verdad explican la demanda.

Las variables que vamos a construir, y por qué cada una:

- **Rezagos de demanda** de una, dos, cuatro y trece semanas. La demanda de
  repuestos tiene memoria corta y un componente anual.
- **Media móvil** de cuatro y trece semanas, y su desviación. Captura nivel y
  volatilidad.
- **Tasa de quiebre de stock** de la semana anterior en ese punto y esa familia.
  Esta es la variable que conecta la operación con el modelo, y en esta data es la
  que más pesa.
- **Semana del año y mes**, como categóricas. No como número: 52 no está cerca de
  1 en una recta, pero sí en el calendario.
- **Atributos del punto**: país, tipo de punto, bahías. Un taller de doce bahías
  no consume como un punto de repuestos.
- **Bandera del periodo del incidente**, la decisión del Paso 1.

**La trampa a evitar, y es la que hunde estos modelos en producción:** todas las
variables tienen que estar disponibles con la información que existía en ese
momento. Si construís la media móvil incluyendo la semana que querés predecir, el
modelo te va a dar un error espectacular en validación y una vergüenza en
producción. Genie Code no te va a avisar de esto solo, hay que pedírselo. El prompt
de [PROMPTS.md, sección 2](PROMPTS.md#2-variables) lo pide explícitamente.

**Cómo sabés que funcionó:** tu tabla de entrenamiento tiene alrededor de
**37 mil filas** con grano de semana por punto por familia, y ninguna variable
usa información posterior a la fecha de la fila. Verificá lo segundo con la
consulta de control que viene en el prompt.

## Paso 3. El modelo, con MLflow registrando todo

**Objetivo:** entrenar, comparar y quedarse con el mejor, con evidencia de por qué.

**Qué hacer:** MLflow ya está activo en el workspace, y el autologging captura
parámetros, métricas y artefactos sin que escribas nada. Lo que sí hay que escribir
es la partición temporal y la comparación contra una línea base.

Dos cosas no negociables en este paso:

**La partición es temporal, nunca aleatoria.** Entrenás con lo anterior y validás
con lo posterior. Un `train_test_split` aleatorio en una serie de tiempo es
información del futuro filtrada al entrenamiento, y da métricas que no se
sostienen.

**Siempre hay una línea base.** Acá es la demanda de la semana anterior, o la
media de las últimas cuatro. Si tu modelo con doce variables no le gana a repetir
la semana pasada, el hallazgo es ese y hay que reportarlo. Es más valioso que un
número lindo sin comparación.

El prompt está en [PROMPTS.md, sección 3](PROMPTS.md#3-el-modelo). Entrená la línea
base, un modelo de regresión con regularización y un modelo de árboles con
gradiente, los tres en corridas separadas dentro del mismo experimento.

**Cómo sabés que funcionó:** en la pestaña **Experiments** ves las tres corridas
con sus métricas, ordenables por MAE, y el modelo de árboles le gana a la línea
base. Métrica principal MAE en unidades, secundaria MAPE ponderado por volumen,
porque el porcentaje se vuelve loco donde la demanda es cercana a cero.

**Para debuggear una corrida que salió mal**, abrí la corrida en MLflow y compará
los parámetros contra la que salió bien. La comparación lado a lado de dos
corridas es la herramienta más subestimada de MLflow.

## Paso 4. Registrar el modelo en Unity Catalog

**Objetivo:** que el modelo deje de vivir en tu notebook y pase a ser un activo
gobernado, con versión, linaje y permisos.

**Qué hacer:** registrá el mejor modelo en Unity Catalog, con nombre de tres
partes.

```python
import mlflow
mlflow.set_registry_uri("databricks-uc")

mlflow.register_model(
    model_uri=f"runs:/{run_id}/model",
    name="inchcape_workshop.ml.demanda_repuestos",
)
```

Cuatro cosas que hay que hacer y que casi nadie hace:

1. **La firma del modelo.** Con `mlflow.models.infer_signature` sobre tus datos de
   entrenamiento. Sin firma, el primer cambio de esquema en la tabla de entrada te
   rompe el scoring en silencio.
2. **La descripción de la versión.** Qué datos usó, qué periodo cubre, cuál es su
   MAE en validación y contra qué línea base. Tres frases.
3. **Un alias.** `@campeon` para la versión que va a scoring. El job del Paso 5
   apunta al alias, no al número de versión, así que promover un modelo nuevo no
   requiere tocar el job.
4. **El linaje.** Entrá al modelo en el Catalog Explorer y mirá la pestaña de
   linaje. Tiene que verse la tabla de entrenamiento que lo alimentó.

**Cómo sabés que funcionó:** el modelo aparece en el Catalog Explorer bajo
`inchcape_workshop.ml`, con su versión 1, su alias `@campeon`, su firma y su
linaje hacia la tabla de variables.

## Paso 5. El job de scoring y las predicciones como Data Product

**Objetivo:** cerrar el círculo. El modelo produce una tabla, y esa tabla es lo
que el negocio consume.

Un modelo que solo existe en el registro no le sirve a nadie. Lo que el negocio
consume es una tabla de predicciones con dueño y contrato, igual que cualquier
otro Data Product.

**Qué hacer:**

1. Escribí el notebook de scoring: carga el modelo por alias, arma las variables
   de la última semana disponible, predice el horizonte de cuatro semanas y
   escribe en `inchcape_workshop.ml.prediccion_demanda`.
2. La tabla de predicciones lleva la versión del modelo en una columna. Cuando
   alguien pregunte por qué la predicción cambió, la respuesta tiene que estar en
   la tabla, no en tu memoria.
3. Documentá y clasificá la tabla como Data Product:

```sql
ALTER TABLE inchcape_workshop.ml.prediccion_demanda SET TAGS (
  'dominio' = 'posventa',
  'tipo' = 'prediccion',
  'modelo' = 'demanda_repuestos',
  'dueño' = 'data-science-andina',
  'refresco' = 'semanal'
);
```

4. Creá el job. En Free Edition no vamos a desplegar con Asset Bundles, así que lo
   creamos con el SDK desde el mismo notebook, que es la versión programática de lo
   mismo. El código está en
   [notebooks/03_crear_job_scoring.py](notebooks/03_crear_job_scoring.py) y no
   requiere nada instalado: el SDK ya viene en el runtime y se autentica solo.

**Cómo sabés que funcionó:** el job aparece en **Jobs y Pipelines**, lo disparás a
mano, termina en verde, y `prediccion_demanda` tiene las predicciones de las
próximas cuatro semanas con la versión del modelo al lado.

## Paso 6. MLOps y CI/CD: qué se llevan a su entorno

**Objetivo:** que se vayan con los archivos y con el criterio, sin haber peleado
con instaladores durante el taller.

Free Edition no permite desplegar Asset Bundles ni conectar Databricks Connect.
Así que este paso funciona distinto: los archivos están en el repositorio, se los
muestro corriendo en demo, y los revisamos juntos.

**Lo que hay en el repositorio:**

- [databricks.yml](databricks.yml), el bundle completo con dos targets, `dev` y
  `prod`, y las diferencias que importan entre ellos.
- [resources/job_scoring.yml](resources/job_scoring.yml), el mismo job del Paso 5
  pero declarado como código, con su agenda y sus notificaciones.
- [resources/job_entrenamiento.yml](resources/job_entrenamiento.yml), el
  reentrenamiento mensual.
- [ci/github-actions-deploy.yml](ci/github-actions-deploy.yml), el pipeline de
  GitHub Actions: valida el bundle en cada pull request, despliega a `dev` al
  fusionar, y a `prod` con aprobación manual. En su repositorio va en
  `.github/workflows/deploy.yml`. Acá lo dejo en `ci/` para que no se ejecute.

**Los cuatro comandos** que van a correr cuando esto esté en su entorno:

```bash
databricks bundle validate -t dev
databricks bundle deploy -t dev
databricks bundle run job_scoring -t dev
databricks bundle deploy -t prod
```

**Las tres cosas que quiero que discutamos**, y que son la conversación que vale
más que los comandos:

1. **Qué diferencia a `dev` de `prod`.** En `dev`, el bundle prefija los recursos
   con tu usuario, el job queda pausado y escribe en un catálogo de desarrollo. En
   `prod` corre con una identidad de servicio y no con la de una persona. Un job de
   producción atado al usuario de alguien es un incidente esperando la renuncia de
   esa persona.
2. **Qué se promueve: el modelo o el código.** Yo promuevo código y reentreno en
   cada ambiente. Promover el artefacto del modelo entre workspaces es válido, pero
   entonces el linaje tiene que cruzar el borde y hay que resolver eso a propósito.
3. **Quién aprueba pasar un modelo a `@campeon`.** El alias es una decisión de
   negocio disfrazada de comando. Necesita un dueño con nombre y una métrica de
   corte acordada antes de necesitarla.

**Databricks Connect**, para desarrollar en VS Code contra el cómputo del
workspace, se los muestro en demo. El archivo de configuración está en
[docs/databricks_connect.md](docs/databricks_connect.md) para cuando lo quieran
montar en su entorno. No lo vamos a instalar hoy.

## Paso 7. Qué te llevás

Cinco minutos, sin pantalla. Responde para vos:

1. ¿Qué modelo que hoy vive en un notebook tuyo debería estar registrado en Unity
   Catalog con firma y alias?
2. ¿Cuál de tus modelos en uso no tiene línea base declarada? Ese es el primero
   que tenés que revisar.
3. ¿Quién aprueba hoy en Inchcape que un modelo pase a producción, y con qué
   criterio escrito?

La tercera respuesta es la que quiero escuchar en el cierre de la tarde.

## Cuando algo se rompe

| Qué ves | Qué hacer |
|---|---|
| `Table or view not found` | El notebook del Paso 0 no terminó. Corré `Run all` de nuevo y esperá la celda de validación. |
| `pip install` falla o se queda colgado | Free Edition tiene la salida a internet restringida. Usá lo que ya viene en el runtime: mlflow, scikit-learn, pandas, pyspark. |
| `Model name must be a three-level namespace` | Falta `mlflow.set_registry_uri("databricks-uc")` antes de registrar. |
| `PERMISSION_DENIED` al registrar el modelo | Falta el esquema. Corré `CREATE SCHEMA IF NOT EXISTS inchcape_workshop.ml;` y volvé a intentar. |
| El MAE de validación es sospechosamente bajo | Casi siempre es fuga de información. Revisá que ningún rezago ni media móvil incluya la semana que estás prediciendo. |
| El entrenamiento agota la cuota diaria | La grilla de hiperparámetros es demasiado grande. Usá la grilla chica del prompt: tres combinaciones alcanzan para ver la diferencia contra la línea base. |
| El job del Paso 5 falla con error de permisos | El job corre con tu identidad. Verificá que el esquema `ml` exista y que tengas permiso de escritura sobre él. |
| `Quota exceeded` o el cómputo no arranca | Se agotó la cuota diaria de la cuenta. Cierra pestañas y notebooks con celdas corriendo. Si ya se agotó, se restablece al día siguiente. |
| Genie Code genera código que falla | Pegale el error completo y escribile `Corregí esto`. No lo arregles a mano en el primer intento. |

## Mapa del repositorio

- [HISTORIA.md](HISTORIA.md), el caso de negocio y el modelo de datos. Leelo primero.
- [PROMPTS.md](PROMPTS.md), todos los prompts de los siete pasos, listos para copiar.
- [SKILLS.md](SKILLS.md), las instrucciones que le tenés que dar a Genie Code para
  que trabaje con las convenciones de ciencia de datos de Inchcape.
- [notebooks/00_setup_datos.sql](notebooks/00_setup_datos.sql), el generador de datos.
- [notebooks/03_crear_job_scoring.py](notebooks/03_crear_job_scoring.py), el job de
  scoring creado con el SDK, sin salir del navegador.
- [databricks.yml](databricks.yml) y [resources/](resources/), el bundle para
  llevar a su entorno.
- [ci/github-actions-deploy.yml](ci/github-actions-deploy.yml), el pipeline de CI/CD.
- [docs/databricks_connect.md](docs/databricks_connect.md), cómo montar el
  desarrollo local cuando lo necesiten.

---

Cualquier duda después del taller, escríbanme. Saúl Caravaca, Solution Architect
de Databricks para Colombia y Costa Rica.
