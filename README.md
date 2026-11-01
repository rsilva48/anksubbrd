# AirPlay Subtitle Bridge

Aplicación personal de iPhone/iPad para navegar automáticamente un catálogo de anime a través de tu bridge, elegir serie, episodio y servidor, y reproducirlo por AirPlay con subtítulos como pistas HLS reales. El bridge también puede guardar el progreso privado para que continúes entre dispositivos.

```text
App iOS: buscar → serie → episodio → servidor
                       │
                       ▼
Bridge local: API pública del sitio → metadatos del reproductor → HLS + VTT
                       │
                       ▼
AVPlayer en iPhone/iPad ───────── AirPlay ─────────► TV
```

No se pega una URL HLS o VTT en la app. El bridge obtiene los metadatos de episodio y servidor usando las mismas solicitudes AJAX públicas que utiliza la página. Consulta los metadatos públicos del reproductor, descifra su fuente temporal y conserva en memoria el HLS y los VTT. Después sirve un manifiesto HLS que declara cada VTT como subtítulo para `AVPlayer`.

Las URLs y tokens temporales del proveedor no se registran en disco y desaparecen al reiniciar el bridge. Si activas un token de bridge, la app recibe sólo su propio token dentro de las URLs HLS temporales que necesita el receptor AirPlay; por eso deben viajar siempre por HTTPS.

## Requisitos del bridge

- Un equipo en la misma red que iPhone/iPad y TV: Windows, Linux, Mac o NAS compatible.
- Node.js 20 o posterior.
- Acceso a Internet desde el bridge.

## Instalar y ejecutar

En el equipo que actuará como bridge:

```sh
cd proxy
npm install
node server.mjs
```

El primer paso instala `cheerio`. No se necesita Chromium, Playwright, ni un perfil de Edge. Permite conexiones entrantes TCP al puerto `8787` en el firewall. Encuentra la IP LAN del equipo y úsala en la app, por ejemplo `http://192.168.1.20:8787`.

Comprueba que el servicio arrancó:

```sh
curl http://127.0.0.1:8787/health
```

Debe responder `{"ok":true}`.

## Registros del bridge

Al arrancar, es normal que sólo aparezca la línea de dirección: no hay actividad hasta que la app se conecte. Esta versión registra cada operación del catálogo, la carga de episodios, el conteo de servidores Sub/Dub, la resolución del reproductor y cualquier error, sin imprimir URLs temporales, tokens ni credenciales.

Después de pulsar **Probar conexión** en la app, la consola debe mostrar como mínimo:

```text
[bridge] GET /health
```

Si no aparece esa línea, el iPhone/iPad no está llegando al equipo del bridge: revisa la IP configurada, que ambos equipos estén en la misma red y que el firewall de Windows permita conexiones entrantes TCP al puerto `8787`. Reinicia `node server.mjs` después de actualizar el código para aplicar los nuevos registros.

## Uso en la app

1. Compila e instala la app iOS.
2. Abre **Configuración**, escribe la dirección de tu bridge local o público HTTPS y usa **Probar conexión**. La URL queda normalizada y guardada en el dispositivo. Es obligatorio completar esa prueba antes de crear, restaurar o importar una identidad.
3. En **Buscar**, busca por título y elige una serie y un episodio.
4. Elige una fuente desde las pestañas `Sub` o `Dub`. La predeterminada se cambia en **Configuración** y es `Sub` inicialmente.
5. Usa el botón AirPlay dentro de los controles nativos del vídeo, no **Duplicar pantalla** desde el Centro de control. La app configura la sesión como vídeo de larga duración para que el TV reciba vídeo, audio y pistas VTT como reproducción externa.

Los resultados separan `PG Rating`, puntuación, tipo (`TV`, `Movie`, `ONA`, `OVA`, `Special`) y año en etiquetas que también funcionan como filtros. Al abrir una serie, las temporadas relacionadas aparecen juntas; al finalizar un episodio se inicia el siguiente con el mismo servidor/tipo cuando está disponible.

La app conserva localmente las últimas 50 reproducciones: serie, carátula, episodio, servidor, fecha y segundo actual. **Continuar viendo** tiene su propia pestaña y el reproductor retoma desde el último segundo guardado. Si ejecutas el bridge con historial (configuración predeterminada), la app sincroniza de manera privada esas entradas entre tus dispositivos; no inicia sesión ni transmite credenciales al sitio de origen.

Cada token representa un usuario distinto en el bridge. Dos dispositivos con el mismo token comparten el historial; un dispositivo con otro token recibe un historial aislado. La app no envía un nombre de perfil que pueda cambiarse para consultar otra lista: el servidor deriva la identidad directamente del token y también impide que una sesión de vídeo de un usuario sea recuperada por otro.

El token de usuario se guarda como un elemento sincronizable del **Llavero de iCloud**, asociado criptográficamente a la URL normalizada del bridge, no a una etiqueta o perfil visible. Con el mismo Apple ID y Llavero de iCloud activado, después de escribir y probar la misma URL en el segundo dispositivo puedes usar **Restaurar desde Llavero de iCloud**; como alternativa permanece la importación manual. La app no consulta ni restaura tokens de otra URL. La primera vez que abras esta versión y pruebes el bridge, migra de forma segura el token y el historial local de las versiones anteriores a esa URL. El bridge conserva únicamente hash y salt del token.

En iPhone el historial se refresca al entrar en **Continuar viendo** y mediante gesto de deslizar hacia abajo. Durante la reproducción se conserva localmente aun cuando el bridge no tenga conexión.

La primera reproducción de un servidor tarda sólo lo necesario para solicitar los metadatos públicos de la fuente. Las siguientes peticiones HLS de esa reproducción pasan por el bridge.

## API local

La app usa estas rutas locales; no necesitas llamarlas manualmente.

- `GET /api/search?q=titulo`
- `POST /api/series` con `{ "watchUrl": "…" }`
- `GET /api/series/:seriesKey/servers?episode=2`
- `POST /api/play` con `{ "seriesKey": "…", "episode": 2, "serverIndex": 0 }`
- `GET /api/history` y `PUT /api/history` para la sincronización privada de progreso; el usuario se deriva del token de acceso. Se conserva solamente el capítulo más reciente de cada serie y los borrados se sincronizan entre dispositivos.

Las sesiones de serie caducan en 20 minutos. El bridge sólo acepta URLs `/watch/...` del origen configurado para el catálogo y no expone un proxy genérico para otros dominios. El historial se guarda en `proxy/data/history.json` por defecto (o en la ruta definida por `HISTORY_STORE_PATH`); esa carpeta está excluida de Git.

## Usarlo fuera de casa con Caddy

Para exponer el bridge únicamente para tus dispositivos, usa un dominio HTTPS y un token privado. No expongas el puerto `8787` al Internet público.

1. En el servidor Linux, instala el proyecto en `/opt/airplay-subtitle-bridge` y ejecuta `npm install` dentro de `proxy`.
2. Crea el usuario de servicio y el archivo privado de entorno. Sólo necesitas configurar una vez un **token administrador**: se usa desde la app para registrar identidades nuevas, no para reproducir ni para acceder al historial.

   ```sh
   sudo useradd --system --home /var/lib/airplay-subtitle-bridge --shell /usr/sbin/nologin airplaybridge
   sudo install -m 600 -o root -g airplaybridge /dev/null /etc/airplay-subtitle-bridge.env
   openssl rand -hex 32 # token administrador
   ```

   Edita `/etc/airplay-subtitle-bridge.env` y guarda ese valor sin espacios adicionales:

   ```ini
   BRIDGE_ADMIN_TOKEN=TOKEN_ADMINISTRADOR
   ```

3. Copia [`deploy/airplay-subtitle-bridge.service.example`](deploy/airplay-subtitle-bridge.service.example) a `/etc/systemd/system/airplay-subtitle-bridge.service`, revísalo si la ruta de Node no es `/usr/bin/node`, y actívalo:

   ```sh
   sudo systemctl daemon-reload
   sudo systemctl enable --now airplay-subtitle-bridge
   ```

4. Copia [`deploy/Caddyfile.example`](deploy/Caddyfile.example) a la configuración de Caddy, sustituye `bridge.example.com`, verifica que el DNS del dominio apunte al servidor y recarga Caddy. El servicio Node escucha sólo en `127.0.0.1`; Caddy publica HTTPS y conserva los encabezados necesarios para que las URL HLS apunten al dominio público.
5. En el primer iPhone abre **Configuración**, escribe y prueba `https://bridge.example.com`; sólo entonces abre **Crear identidad privada**, introduce una vez el token administrador, genera el token y respáldalo antes de guardarlo. Con el mismo Apple ID y Llavero de iCloud activado, en el segundo iPhone escribe y prueba exactamente esa misma URL y usa **Restaurar desde Llavero de iCloud** para compartir la lista. En el iPad crea otra identidad con el token administrador; su token nuevo tendrá un historial completamente aislado. Si no usas Llavero de iCloud, importa manualmente el token correspondiente. El token administrador no queda guardado en la app.

No actives registros de acceso detallados para este host de Caddy: las URL temporales de reproducción llevan un token de acceso. El bridge no registra ese valor ni las URL HLS completas.

## Compilar la app iOS sin Mac

El workflow [`.github/workflows/ios-build.yml`](.github/workflows/ios-build.yml) se ejecuta en macOS dentro de GitHub Actions. Sube esta carpeta a un repositorio GitHub y ejecuta **Actions → Build iOS app → Run workflow**. Genera el artefacto `AirPlaySubtitlePlayer-unsigned.ipa`.

El IPA no viene firmado, pero es el formato que espera ByteLoader. Descárgalo desde el artefacto de Actions, arrástralo a ByteLoader y éste lo firma e instala con tu Apple ID. Con una cuenta Apple gratuita, la firma normalmente se renueva cada siete días; ByteLoader puede renovarla mientras el iPhone y PC estén disponibles en la misma red. [Guía oficial de ByteLoader](https://byteloader.byteknotlabs.com/guide)

## Límites técnicos

- Si una fuente no entrega HLS y VTT, no podrá convertirse en subtítulos AirPlay por este bridge.
- No se admiten DRM, paywalls ni mecanismos de acceso que impidan al receptor AirPlay recuperar el manifiesto.
- Para una conexión local, el TV debe poder alcanzar la IP LAN del bridge. Para uso remoto, tanto iPhone/iPad como el receptor AirPlay deben tener salida a Internet hacia el dominio HTTPS de Caddy.
- El inicio de sesión en el sitio de origen no es necesario ni se automatiza: el progreso compartido vive en tu bridge protegido por token, no en el sitio.
