# Desarrollo local con Databricks Connect

**Esto no se monta en el taller.** Free Edition no permite conectar Databricks
Connect, y no les voy a pedir instalar nada en su máquina un jueves a las tres de
la tarde. Se lo muestro corriendo desde mi entorno y este archivo queda para
cuando lo quieran montar en su plataforma.

## Para qué sirve y para qué no

Databricks Connect deja que su editor local, VS Code o PyCharm, ejecute el código
Spark en el cómputo del workspace. El editor es local, el cómputo es remoto.

Sirve para: escribir con el editor que ya usan, con su linter, su formateador y su
debugger, sin perder la potencia del cluster ni bajarse los datos.

No sirve para: reemplazar los notebooks. Para explorar, el notebook sigue siendo
mejor. Databricks Connect gana cuando el código empieza a ser una librería con
tests, y ahí la diferencia es grande.

## Qué necesita

- Python de la misma versión menor que el runtime del workspace. Si el runtime usa
  Python 3.11, el entorno local también. Esto es la causa número uno de errores
  raros al arrancar.
- Un entorno virtual limpio. `pyspark` instalado en el mismo entorno entra en
  conflicto con `databricks-connect`: hay que desinstalarlo.
- La extensión de Databricks para VS Code, opcional pero recomendada. Administra la
  configuración y deja correr archivos en el workspace desde el editor.

## Montarlo

```bash
python -m venv .venv && source .venv/bin/activate
pip uninstall -y pyspark
pip install --upgrade "databricks-connect==16.*" databricks-sdk
```

La versión de `databricks-connect` tiene que coincidir con la major y minor del
runtime del workspace. Un runtime 16.4 pide `databricks-connect==16.4.*`.

## Autenticación

Perfil en `~/.databrickscfg`, nunca credenciales en el código:

```ini
[inchcape-dev]
host          = https://adb-XXXXXXXXXXXXXXXX.XX.azuredatabricks.net
client_id     = <client id del service principal>
client_secret = <secret del service principal>
serverless_compute_id = auto
```

Con `serverless_compute_id = auto` el código corre en cómputo serverless y no hay
cluster que prender ni apagar. Si necesitan un cluster clásico, se reemplaza por
`cluster_id`.

## Probar que funciona

```python
from databricks.connect import DatabricksSession

spark = DatabricksSession.builder.profile("inchcape-dev").getOrCreate()

df = spark.table("inchcape_workshop.ops.fact_parts_sales")
print(df.count())
df.groupBy("dealer_id").sum("monto_usd").orderBy("sum(monto_usd)", ascending=False).show(5)
```

Si el `count()` devuelve el número de filas de la tabla, la conexión funciona y el
cómputo es remoto.

## Cuando algo se rompe

| Qué ves | Qué hacer |
|---|---|
| `Python version mismatch` | El Python local no coincide con el del runtime. Recreá el entorno virtual con la versión correcta. |
| `py4j` o `JavaPackage` en el error | Quedó `pyspark` instalado en el mismo entorno. `pip uninstall pyspark` y volvé a probar. |
| `Unable to authenticate` | El perfil no existe o el nombre está mal escrito. Verificá con `databricks auth env --profile inchcape-dev`. |
| El código corre pero lentísimo | Están trayendo datos a la máquina local con un `.collect()` o un `.toPandas()` sobre todo el DataFrame. Filtren y agreguen antes de traer. |
| `Cluster not found` o el cómputo no arranca | El `cluster_id` apunta a algo que ya no existe. Con serverless, usen `serverless_compute_id = auto`. |

## Lo que quiero que quede de esto

Databricks Connect no es la parte importante del Paso 6. La parte importante es
que el código del modelo viva en un repositorio con tests, y que llegue al
workspace por un pipeline y no por un copiar y pegar. Databricks Connect es lo que
hace ese trabajo agradable, no lo que lo hace posible.
