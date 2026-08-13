# Taller Inchcape: de la exploración al modelo en producción

Guía para el grupo de **Data Science**.
Workshop Inchcape, Medellín, agosto 2026.

Arrancás explorando por qué se rompió la operación de posventa en marzo, y
terminás con un modelo de pronóstico de demanda registrado en Unity Catalog, un
job de scoring que corre solo, las predicciones publicadas como Data Product para
que el negocio las consuma sin pedirte nada, y el mismo modelo servido como API
para quien lo necesite en el momento.

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
- **El runtime trae MLflow 2.11**, y esa versión no puede registrar modelos en
  Unity Catalog: falla al subir los artefactos. Del Paso 3 en adelante, los
  notebooks arrancan con estas dos líneas y todo funciona. Vienen dentro de los
  prompts, y quiero que sepas por qué están:

```python
%pip install --upgrade "mlflow[databricks]" "scikit-learn==1.5.2" --quiet
%restart_python
```

`pip install` sí funciona contra PyPI desde el cómputo. Lo que no hay es salida
libre a cualquier host de internet, así que un paquete que se descargue de otro
lado sí puede fallar.

La versión de scikit-learn está fijada a propósito, y es la línea que más dolores
de cabeza ahorra. Un modelo de scikit-learn se guarda serializado con la versión
que lo entrenó, y solo lo abre esa misma versión. El notebook interactivo y el job
programado del Paso 5 pueden arrancar con runtimes distintos, y ahí el modelo que
entrenaste el martes deja de cargar el miércoles con un error que no dice nada
útil. Fijar la versión en los dos lados, entrenamiento y scoring, hace que eso no
pase. Es la misma disciplina que en producción resuelve un contenedor.

El **Paso 7 es la parte de CI/CD**, y ahí sí hay cosas que no se pueden ejecutar
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

**Objetivo:** construir la feature table con grano semana por punto de red por
familia, y las variables que de verdad explican la demanda.

**Y que sea una feature table de verdad, no una tabla suelta.** En Unity Catalog
una tabla Delta con clave primaria declarada es una feature table: aparece en el
buscador de features, el linaje la conecta con los modelos que la consumen, y
cualquiera puede reusar tus variables en vez de volver a calcularlas. La
diferencia entre las dos cosas son tres líneas de DDL:

```sql
CONSTRAINT features_demanda_pk PRIMARY KEY (dealer_id, familia, semana)
```

Las columnas de la clave van con `NOT NULL`, y la tabla lleva `COMMENT` en cada
columna y etiquetas de dominio y dueño. El prompt lo pide todo junto.

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

**Cómo sabés que funcionó:** tu feature table tiene **43.654 filas**, con grano de
semana por punto por familia y clave primaria declarada. Son 39 semanas de las 52
del periodo: las trece primeras se caen porque el rezago de trece semanas todavía
no existe, y eso está bien. Si te quedan las 52 completas, algún rezago se está
rellenando con un valor inventado en vez de descartarse.

Lo segundo que hay que verificar es que ninguna variable use información posterior
a la fecha de la fila. Para eso está la consulta de control del prompt.

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

**Qué hacer:** registrá el mejor modelo en Unity Catalog. Lo que cambia respecto
de un registro común es el nombre de tres partes, catálogo, esquema y modelo:

```python
%pip install --upgrade "mlflow[databricks]" --quiet
%restart_python
```

```python
import mlflow
mlflow.set_registry_uri("databricks-uc")   # antes de tocar nada más de mlflow

mlflow.register_model(
    model_uri=f"runs:/{run_id}/model",
    name="inchcape_workshop.ml.demanda_repuestos",
)
```

**Dos detalles del entorno que ahorran media hora**, y por eso van arriba y no en
la tabla de problemas del final:

- La actualización de MLflow no es opcional. La versión que trae el runtime falla
  al subir los artefactos del modelo al almacenamiento de Unity Catalog, con un
  error de permisos de S3 que no dice nada útil.
- `set_registry_uri` va **antes** que `set_experiment` y que cualquier
  `log_model`. Si lo llamás después, MLflow consulta una configuración de Spark
  que en serverless está bloqueada, y el notebook corta con
  `CONFIG_NOT_AVAILABLE`.

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

Esas tres líneas de arriba son para que veas la forma del nombre. Lo que corrés
es el prompt de
[PROMPTS.md, sección 4](PROMPTS.md#4-registro-en-unity-catalog), que pide el
código completo con las cuatro cosas adentro y termina cargando el modelo por
alias para probar que la firma acepta la entrada.

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

1. Escribí el notebook de scoring con
   [PROMPTS.md, sección 5.1](PROMPTS.md#5-scoring-y-data-product): carga el modelo
   por alias, arma las variables de la última semana disponible, predice el
   horizonte de cuatro semanas y escribe en
   `inchcape_workshop.ml.prediccion_demanda`. Guardalo con un nombre que te
   acuerdes, porque el job del punto 4 va a apuntar a ese path.
2. La tabla de predicciones lleva la versión del modelo en una columna. Cuando
   alguien pregunte por qué la predicción cambió, la respuesta tiene que estar en
   la tabla, no en tu memoria.
3. Documentá y clasificá la tabla como Data Product. Las etiquetas de abajo son
   una parte. [PROMPTS.md, sección 5.2](PROMPTS.md#52-el-data-product)
   completa el producto con los `COMMENT`, los `GRANT` para que el negocio lea sin
   modificar, y la vista `vw_riesgo_quiebre`, que cruza la predicción con el
   inventario y el punto de reorden. Esa vista es la que de verdad abre el equipo
   de compras: la tabla de predicciones es el insumo, la vista es el producto.

   **El criterio de la vista es una decisión de negocio, miralo.** Si
   listás solo donde la demanda de cuatro semanas supera el stock actual, te
   quedan tres combinaciones de 1.075: para cuando aparecen ahí, compras ya llegó
   tarde. El criterio útil es el otro, dónde el stock cae por debajo del punto de
   reorden después de servir esas cuatro semanas, y ahí son 51. Esa es la lista
   con la que alguien puede trabajar el lunes.

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
   mismo. Pedíselo a Genie Code con
   [PROMPTS.md, sección 5.3](PROMPTS.md#5-scoring-y-data-product), donde le pasás
   el path de tu notebook de scoring y le pedís que el job quede pausado y sea
   idempotente. El SDK ya viene en el runtime y se autentica solo, así que no hay
   que instalar ni configurar nada.

   Si preferís no escribirlo, el mismo job está resuelto en
   [notebooks/03_crear_job_scoring.py](notebooks/03_crear_job_scoring.py). Resuelve
   tu usuario solo, pero espera el notebook de scoring en
   `inchcape/02_scoring_demanda` dentro de tu carpeta. Si lo guardaste con otro
   nombre o en otra carpeta, cambiá la constante `NOTEBOOK_SCORING` antes de
   correrlo.

5. **Poné una alerta sobre la vista.** Un Data Product que nadie mira no cambia
   ninguna decisión. Con
   [PROMPTS.md, sección 5.4](PROMPTS.md#54-la-alerta-sobre-el-riesgo-de-quiebre)
   creás una alerta de Databricks SQL que corre los lunes a las 7 y dispara cuando
   `vw_riesgo_quiebre` trae filas. Dejala pausada. El punto es que la cadena
   termine en una persona con un correo, y no en una tabla que hay que acordarse
   de abrir.

**Cómo sabés que funcionó:** el job aparece en **Jobs y Pipelines**, lo disparás a
mano, termina en verde, y `prediccion_demanda` tiene **4.300 filas**, que son las
1.075 combinaciones de punto y familia por las cuatro semanas del horizonte, cada
una con la versión del modelo al lado. Corré el job dos veces: si la segunda deja
8.600 filas, el scoring no es idempotente y hay que arreglarlo antes de agendarlo.

## Paso 6. El modelo como API: Model Serving y AI Gateway

**Objetivo:** el mismo modelo, un segundo canal de entrega. El job semanal del
Paso 5 responde "qué compro este mes para las 1.075 combinaciones". Un endpoint
responde "y si este punto suma dos bahías, cuánto pide", en el momento en que
alguien lo pregunta.

Los dos canales sirven a decisiones distintas y por eso conviven. El error es
elegir uno por costumbre: si la respuesta se consume en una planilla los lunes,
el batch alcanza y sale más barato; si un sistema la necesita mientras un humano
espera, hace falta el endpoint.

**Qué hacer:** el prompt de
[PROMPTS.md, sección 6](PROMPTS.md#6-model-serving-y-ai-gateway) pide el código
completo con el SDK. Tres cosas que van adentro y que son las que importan:

1. **El endpoint sirve el alias, no un número de versión.** Resolvés `@campeon` a
   su versión al crear el endpoint, y cuando promuevas un modelo nuevo actualizás
   la configuración apuntando al alias otra vez. Nadie tiene que acordarse de qué
   número estaba corriendo.
2. **Escala a cero.** Sin tráfico, el endpoint se apaga y no consume. La primera
   llamada después de un rato tarda más porque tiene que despertar. Es el
   intercambio correcto para un modelo que se consulta a ratos, y hay que decirlo
   antes de que alguien mida la latencia del primer request y saque conclusiones.
3. **AI Gateway encima.** Con dos líneas más le ponés seguimiento de uso y un
   límite de llamadas por minuto. El límite no es para ahorrar: es para que un
   bucle mal escrito en un sistema cliente no se lleve puesto el presupuesto un
   sábado.

**Cómo sabés que funcionó:** el endpoint aparece en **Serving** en estado
**Ready**, y le mandás la misma fila que le pasaste al modelo cargado en el
notebook del Paso 4. Tiene que devolver **exactamente el mismo número**. Si
difiere, algo se transformó en el camino y hay que encontrarlo ahora y no cuando
lo consuma un sistema.

Crear el endpoint tarda entre cuatro y quince minutos la primera vez, porque
construye la imagen con las dependencias del modelo. Arrancalo y seguí con el
Paso 7 mientras se aprovisiona.

**Un límite de Free Edition que sí importa:** las *inference tables*, que guardan
cada request y cada respuesta en una tabla de Unity Catalog para auditar y para
detectar deriva, no están habilitadas en esta edición. El resto de AI Gateway sí.
En su entorno esa tabla es lo primero que activaría, porque es la que responde
"qué le preguntaron al modelo el día que dio un número raro".

## Paso 7. MLOps y CI/CD: qué se llevan a su entorno

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
  reentrenamiento mensual, con la evaluación del candidato como última tarea.
- Los cinco notebooks que esos dos jobs orquestan, en
  [notebooks/](notebooks/): variables, entrenamiento, scoring, control de calidad
  sobre la predicción y evaluación del candidato. Son la versión terminada de lo
  que armaste con Genie Code en los Pasos 2 a 5, con los parámetros declarados
  como widgets para que el bundle se los pase.
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

Los tres prompts de [PROMPTS.md, sección 7](PROMPTS.md#7-mlops-y-cicd) sirven para
leer estos archivos con Genie Code al lado, hoy acá o el lunes en su entorno. La
7.1 compara `dev` contra `prod` y dice qué le falta al bundle para una producción
real. La 7.2 recorre el flujo de CI/CD y qué secretos necesita configurados. La
7.3 redacta la política de promoción de la tercera discusión, con nombres de rol y
no de persona, que es el entregable que se pueden llevar escrito.

**Databricks Connect**, para desarrollar en VS Code contra el cómputo del
workspace, se los muestro en demo. El archivo de configuración está en
[docs/databricks_connect.md](docs/databricks_connect.md) para cuando lo quieran
montar en su entorno. No lo vamos a instalar hoy.

## Paso 8. Qué te llevás

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
| `Model name must be a three-level namespace` | Falta `mlflow.set_registry_uri("databricks-uc")` antes de registrar. |
| `PERMISSION_DENIED` al registrar el modelo | Falta el esquema. Corré `CREATE SCHEMA IF NOT EXISTS inchcape_workshop.ml;` y volvé a intentar. |
| `Failed to upload ... AccessDenied` al registrar el modelo | Es la versión de MLflow del runtime. Poné `%pip install --upgrade "mlflow[databricks]" "scikit-learn==1.5.2" --quiet` y `%restart_python` en la primera celda, y volvé a correr desde ahí. |
| `Can't get attribute '__pyx_unpickle_CyHalfSquaredError'` o `Untrusted types found in the file` al cargar el modelo | El job arrancó con una versión de scikit-learn distinta de la que entrenó. Fijá `scikit-learn==1.5.2` en la primera celda del notebook de entrenamiento y en la del scoring, reentrená y volvé a correr. Casi siempre aparece solo desde el job, nunca desde el notebook donde entrenaste. |
| `CONFIG_NOT_AVAILABLE` sobre `spark.mlflow.modelRegistryUri` | `set_registry_uri("databricks-uc")` quedó después de otra llamada a MLflow. Movelo a la primera línea, antes de `set_experiment`. |
| `A sparse matrix was passed, but dense data is required` | El `OneHotEncoder` está devolviendo matriz dispersa. Agregale `sparse_output=False`. |
| `Can not safely convert int64 to int32` al predecir | La firma del modelo fijó 32 bits y pandas produce 64. `.astype("int32")` en esa columna. Es la firma haciendo su trabajo. |
| `Syntax error at or near '('` en la tabla de variables | Spark no deja extender una ventana nombrada con `ROWS BETWEEN`. Que escriba cada `OVER (PARTITION BY ... ORDER BY ...)` completo. |
| El endpoint del Paso 6 lleva rato en `Not Ready` | La primera creación construye la imagen con las dependencias del modelo y tarda entre cuatro y quince minutos. Seguí con el Paso 7 y volvé después. |
| `Inference table is not currently supported` | Las tablas de inferencia no están habilitadas en Free Edition. Aplicá AI Gateway solo con seguimiento de uso y límite de llamadas. |
| El MAE de validación es sospechosamente bajo | Casi siempre es fuga de información. Revisá que ningún rezago ni media móvil incluya la semana que estás prediciendo. |
| El entrenamiento agota la cuota diaria | La grilla de hiperparámetros es demasiado grande. Usá la grilla chica del prompt: tres combinaciones alcanzan para ver la diferencia contra la línea base. |
| El job del Paso 5 falla con error de permisos | El job corre con tu identidad. Verificá que el esquema `ml` exista y que tengas permiso de escritura sobre él. |
| `Quota exceeded` o el cómputo no arranca | Se agotó la cuota diaria de la cuenta. Cierra pestañas y notebooks con celdas corriendo. Si ya se agotó, se restablece al día siguiente. |
| Genie Code genera código que falla | Pegale el error completo y escribile `Corregí esto`. No lo arregles a mano en el primer intento. |

## Mapa del repositorio

- [HISTORIA.md](HISTORIA.md), el caso de negocio y el modelo de datos. Leelo primero.
- [PROMPTS.md](PROMPTS.md), todos los prompts del recorrido, listos para copiar.
- [SKILLS.md](SKILLS.md), las instrucciones que le tenés que dar a Genie Code para
  que trabaje con las convenciones de ciencia de datos de Inchcape.
- [notebooks/00_setup_datos.sql](notebooks/00_setup_datos.sql), el generador de datos.
- [notebooks/01_features_demanda.py](notebooks/01_features_demanda.py),
  [notebooks/02_entrenamiento_demanda.py](notebooks/02_entrenamiento_demanda.py),
  [notebooks/02_scoring_demanda.py](notebooks/02_scoring_demanda.py),
  [notebooks/04_control_prediccion.py](notebooks/04_control_prediccion.py) y
  [notebooks/05_evaluar_candidato.py](notebooks/05_evaluar_candidato.py): el
  recorrido completo ya resuelto. Pedíselos a Genie Code durante el taller, que
  es donde se aprende, y usá estos para comparar contra lo que te salió o para
  desatascarte.
- [notebooks/03_crear_job_scoring.py](notebooks/03_crear_job_scoring.py), el job de
  scoring ya resuelto con el SDK, por si preferís no pedírselo a Genie Code.
  Resuelve tu usuario solo y espera el notebook de scoring en
  `inchcape/02_scoring_demanda`; si lo guardaste en otro lado, ajustá
  `NOTEBOOK_SCORING` antes de correrlo.
- [databricks.yml](databricks.yml) y [resources/](resources/), el bundle para
  llevar a su entorno.
- [ci/github-actions-deploy.yml](ci/github-actions-deploy.yml), el pipeline de CI/CD.
- [docs/databricks_connect.md](docs/databricks_connect.md), cómo montar el
  desarrollo local cuando lo necesiten.

---

Cualquier duda después del taller, escríbanme. Saúl Caravaca, Solution Architect
de Databricks para Colombia y Costa Rica.
