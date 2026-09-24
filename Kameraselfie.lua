-- Judul: Kamera selfie by novan
-- Versi: v4.3
-- Fungsi: Kamera selfie dan perekam video otomatis dengan panduan suara untuk tunanetra, pemilih kamera di layar utama, tombol berhenti rekam dengan fokus otomatis, menu tindakan (buka/putar di dalam skrip, bagikan ke aplikasi lain, hapus, ubah nama) setelah mengambil foto atau video, dan pembaruan online.

require "import"
import "android.hardware.Camera"
import "android.hardware.Sensor"
import "android.hardware.SensorEvent"
import "android.hardware.SensorEventListener"
import "android.hardware.SensorManager"
import "android.media.MediaRecorder"
import "android.media.MediaScannerConnection"
import "android.view.SurfaceView"
import "android.view.SurfaceHolder"
import "android.view.ViewGroup"
import "android.view.View"
import "android.view.Gravity"
import "android.view.WindowManager"
import "android.view.KeyEvent"
import "android.widget.FrameLayout"
import "android.widget.LinearLayout"
import "android.widget.Button"
import "android.widget.TextView"
import "android.widget.EditText"
import "android.widget.ImageView"
import "android.widget.VideoView"
import "android.widget.MediaController"
import "android.graphics.Bitmap"
import "android.graphics.BitmapFactory"
import "android.graphics.Color"
import "android.app.AlertDialog"
import "android.content.Context"
import "android.content.DialogInterface"
import "android.content.Intent"
import "android.content.ContentValues"
import "android.content.ContentUris"
import "android.provider.MediaStore"
import "android.net.Uri"
import "android.os.Handler"
import "android.os.Looper"
import "android.os.Vibrator"
import "android.os.StrictMode"
import "android.media.MediaActionSound"
import "java.io.File"
import "java.io.FileOutputStream"
import "java.io.FileInputStream"
import "java.io.InputStreamReader"
import "java.io.BufferedReader"
import "java.net.URL"
import "java.net.HttpURLConnection"
import "java.lang.System"
import "java.lang.String"
import "java.lang.Thread"
import "java.lang.Runnable"
import "java.lang.reflect.Array"

local SCRIPT_TITLE = "Kamera selfie by novan"
local SCRIPT_VERSION = "v4.3"
local UPDATE_URL = "https://raw.githubusercontent.com/novanblind/Kameraselfie/main/Kameraselfie.lua"

-- Melonggarkan kebijakan StrictMode secara aman
pcall(function()
  local policyBuilder = StrictMode.VmPolicy.Builder()
  StrictMode.setVmPolicy(policyBuilder.build())
end)
pcall(function()
  local m = StrictMode.class.getMethod("disableDeathOnFileUriExposure", nil)
  m.invoke(nil, nil)
end)

-- Ambil lokasi berkas skrip di thread utama sebelum background thread berjalan
local CURRENT_SCRIPT_PATH = nil
pcall(function()
  local info = debug.getinfo(1, "S")
  if info and info.source and info.source:sub(1, 1) == "@" then
    CURRENT_SCRIPT_PATH = info.source:sub(2)
  end
end)

local mainHandler = Handler(Looper.getMainLooper())
local vibrator = service.getSystemService(Context.VIBRATOR_SERVICE)
local sensorManager = service.getSystemService(Context.SENSOR_SERVICE)
local accelerometer = nil
if sensorManager then
  pcall(function()
    accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
  end)
end

-- Inisialisasi suara jepret kamera bawaan
local actionSound = MediaActionSound()
pcall(function()
  actionSound.load(MediaActionSound.SHUTTER_CLICK)
end)

-- Konfigurasi tersimpan
local sp = service.getSharedPreferences("novan_offline_selfie_config", Context.MODE_PRIVATE)

local cameraFacing = sp.getString("camera_facing", "front")
local HOLD_DURATION = sp.getInt("hold_duration", 1000)
local vibrationEnabled = sp.getBoolean("vibration_enabled", true)
local shutterSoundEnabled = sp.getBoolean("shutter_sound_enabled", true)
local selectedVideoWidth = sp.getInt("video_width", 1280)
local selectedVideoHeight = sp.getInt("video_height", 720)
local flashMode = sp.getString("camera_flash_mode", "off")
local shakeSensitivity = sp.getInt("shake_sensitivity", 22)
local shakeStopEnabled = sp.getBoolean("shake_stop_enabled", true)

local cam = nil
local dialog = nil
local frame = nil
local tvStatus = nil
local btnMode = nil
local btnRecordVideo = nil
local btnStopRecord = nil
local btnSwitchCam = nil
local currentHolder = nil
local isCapturing = false
local isSettingsOpen = false
local isRecordingVideo = false
local isCameraOpening = false
local isSharingAction = false
local isFaceDetectionActive = false
local mediaRecorder = nil
local perfectStartTime = nil
local lastVideoFile = nil
local videoStartTime = 0

local currentMode = "photo"

local lastSpeakTime = 0
local lastSpeakText = ""
local wasFaceDetected = false
local lastNoFaceAlertTime = 0
local lastFaceProcessTime = 0

-- Cache ID Kamera
local cachedFrontCamId = -1
local cachedBackCamId = -1

-- Variabel sensor goyangan
local lastSensorX, lastSensorY, lastSensorZ = 0, 0, 0
local lastSensorUpdate = 0
local lastShakeTriggerTime = 0
local isSensorRegistered = false

local stopVideoRecording
local startVideoRecording
local showCameraSelectionDialog
local showMediaResultDialog
local processFaces
local takeSelfiePhoto

-- Pengambilan & penyimpanan resolusi per-posisi kamera (depan/belakang)
local function getSavedPicSize(facing)
  local w = sp.getInt("pic_width_" .. facing, 0)
  local h = sp.getInt("pic_height_" .. facing, 0)
  return w, h
end

local function savePicSize(facing, w, h)
  sp.edit().putInt("pic_width_" .. facing, w).putInt("pic_height_" .. facing, h).apply()
end

-- Sinkronisasi berkas ke galeri sistem
local function scanMediaFile(file)
  if not file then return end
  pcall(function()
    MediaScannerConnection.scanFile(service, { file.getAbsolutePath() }, nil, nil)
  end)
  pcall(function()
    local scanIntent = Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE)
    scanIntent.setData(Uri.fromFile(file))
    service.sendBroadcast(scanIntent)
  end)
end

-- Dekode gambar hemat RAM (Mencegah OutOfMemory / Pembaca Layar restart)
local function decodeSampledBitmap(filePath, reqWidth, reqHeight)
  local bmp = nil
  pcall(function()
    local opts = BitmapFactory.Options()
    opts.inJustDecodeBounds = true
    BitmapFactory.decodeFile(filePath, opts)

    local height = opts.outHeight
    local width = opts.outWidth
    local inSampleSize = 1

    if height > reqHeight or width > reqWidth then
      local halfHeight = height / 2
      local halfWidth = width / 2
      while (halfHeight / inSampleSize) >= reqHeight and (halfWidth / inSampleSize) >= reqWidth do
        inSampleSize = inSampleSize * 2
      end
    end

    opts.inSampleSize = inSampleSize
    opts.inJustDecodeBounds = false
    pcall(function()
      opts.inPreferredConfig = Bitmap.Config.RGB_565
    end)
    bmp = BitmapFactory.decodeFile(filePath, opts)
  end)
  return bmp
end

-- Menghasilkan URI yang aman dibagikan
local function getShareableUri(file, isVideo)
  if not file or not file.exists() then return nil end
  local uri = nil
  local mime = isVideo and "video/mp4" or "image/jpeg"
  local baseUri = isVideo and MediaStore.Video.Media.EXTERNAL_CONTENT_URI or MediaStore.Images.Media.EXTERNAL_CONTENT_URI

  pcall(function()
    local cr = service.getContentResolver()
    local cursor = cr.query(
      baseUri,
      { "_id" },
      "_data = ?",
      { file.getAbsolutePath() },
      nil
    )
    if cursor then
      if cursor.moveToFirst() then
        local id = cursor.getLong(0)
        uri = ContentUris.withAppendedId(baseUri, id)
      end
      cursor.close()
    end
  end)
  if uri then return uri end

  pcall(function()
    local values = ContentValues()
    values.put("_data", file.getAbsolutePath())
    values.put("_display_name", file.getName())
    values.put("mime_type", mime)
    uri = service.getContentResolver().insert(baseUri, values)
  end)
  if uri then return uri end

  pcall(function()
    local fp = nil
    pcall(function() fp = luajava.bindClass("androidx.core.content.FileProvider") end)
    if not fp then
      pcall(function() fp = luajava.bindClass("android.support.v4.content.FileProvider") end)
    end
    if fp then
      local pkg = service.getPackageName()
      local auths = { pkg .. ".fileprovider", pkg .. ".provider", pkg .. ".FileProvider", pkg }
      for _, auth in ipairs(auths) do
        local ok, res = pcall(function() return fp.getUriForFile(service, auth, file) end)
        if ok and res then
          uri = res
          break
        end
      end
    end
  end)
  if uri then return uri end

  pcall(function()
    uri = Uri.fromFile(file)
  end)

  return uri
end

local function displayOverlayDialog(builder)
  local dlg = builder.create()
  local win = dlg.getWindow()
  if win then
    win.setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
  end
  dlg.show()
  return dlg
end

local function triggerVibrate(ms)
  if not vibrationEnabled then return end
  pcall(function()
    if vibrator and vibrator.hasVibrator() then
      vibrator.vibrate(ms)
    end
  end)
end

local function playShutterSound()
  if not shutterSoundEnabled then return end
  pcall(function()
    actionSound.play(MediaActionSound.SHUTTER_CLICK)
  end)
end

-- Listener sensor akselerometer untuk stop video
local sensorListener = SensorEventListener{
  onSensorChanged = function(event)
    if not isRecordingVideo or not shakeStopEnabled then return end
    local curTime = System.currentTimeMillis()
    if (curTime - lastSensorUpdate) > 70 then
      lastSensorUpdate = curTime
      local x = event.values[0]
      local y = event.values[1]
      local z = event.values[2]

      local deltaX = math.abs(x - lastSensorX)
      local deltaY = math.abs(y - lastSensorY)
      local deltaZ = math.abs(z - lastSensorZ)

      lastSensorX = x
      lastSensorY = y
      lastSensorZ = z

      local totalDelta = deltaX + deltaY + deltaZ
      if totalDelta > shakeSensitivity then
        if (curTime - lastShakeTriggerTime) > 2000 then
          lastShakeTriggerTime = curTime
          mainHandler.post(Runnable{
            run = function()
              stopVideoRecording()
            end
          })
        end
      end
    end
  end,
  onAccuracyChanged = function(sensor, accuracy) end
}

local function registerShakeListener()
  if not shakeStopEnabled then return end
  if sensorManager and accelerometer and not isSensorRegistered then
    pcall(function()
      sensorManager.registerListener(sensorListener, accelerometer, SensorManager.SENSOR_DELAY_UI)
      isSensorRegistered = true
    end)
  end
end

local function unregisterShakeListener()
  if sensorManager and isSensorRegistered then
    pcall(function()
      sensorManager.unregisterListener(sensorListener)
      isSensorRegistered = false
    end)
  end
end

-- Fitur periksa versi baru stabil
local function checkUpdateWithDialog(isManual)
  if isManual then
    service.speak("Sedang memeriksa versi baru...")
  end

  Thread(Runnable{
    run = function()
      local checkSuccess = false
      local hasNewVersion = false
      local remoteVersion = ""
      local remoteDesc = ""
      local newContent = ""

      pcall(function()
        local url = URL(UPDATE_URL)
        local conn = url.openConnection()
        conn.setRequestMethod("GET")
        conn.setConnectTimeout(10000)
        conn.setReadTimeout(10000)
        conn.setUseCaches(false)
        conn.setInstanceFollowRedirects(true)
        conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android)")
        conn.setRequestProperty("Accept", "*/*")

        local responseCode = conn.getResponseCode()
        if responseCode == 200 then
          local is = conn.getInputStream()
          local reader = BufferedReader(InputStreamReader(is, "UTF-8"))
          local sb = {}
          local line = reader.readLine()
          while line ~= nil do
            table.insert(sb, line)
            line = reader.readLine()
          end
          reader.close()
          is.close()

          newContent = table.concat(sb, "\n")
          if #newContent > 300 then
            checkSuccess = true
            local rVer = newContent:match('SCRIPT_VERSION%s*=%s*"([^"]+)"') or newContent:match('%-%-%s*Versi:%s*(v[%d%.]+)')
            local rDesc = newContent:match('%-%-%s*Fungsi:%s*([^\r\n]+)')
              or newContent:match('%-%-%s*Fitur:%s*([^\r\n]+)')
              or newContent:match('%-%-%s*Catatan:%s*([^\r\n]+)')
              or "Pembaruan kamera belakang cepat, bebas macet, dan panduan suara instan."

            if rVer and rVer ~= SCRIPT_VERSION then
              hasNewVersion = true
              remoteVersion = rVer
              remoteDesc = rDesc
            end
          end
        end
        conn.disconnect()
      end)

      mainHandler.post(Runnable{
        run = function()
          if hasNewVersion then
            local builder = AlertDialog.Builder(service)
              .setTitle("Versi Baru Tersedia")
              .setMessage("Versi baru tersedia: " .. remoteVersion .. "\n\nFungsi:\n" .. remoteDesc .. "\n\nVersi saat ini: " .. SCRIPT_VERSION .. "\n\nApakah Anda ingin memperbarui skrip sekarang?")
              .setPositiveButton("Perbarui", function(dlg)
                dlg.dismiss()
                service.speak("Mengunduh pembaruan...")

                Thread(Runnable{
                  run = function()
                    local writeSuccess = false
                    pcall(function()
                      if CURRENT_SCRIPT_PATH then
                        local cFile = File(CURRENT_SCRIPT_PATH)
                        local fos = FileOutputStream(cFile)
                        fos.write(String(newContent).getBytes("UTF-8"))
                        fos.flush()
                        fos.close()
                        writeSuccess = true
                      end
                    end)

                    mainHandler.post(Runnable{
                      run = function()
                        if writeSuccess then
                          local doneBuilder = AlertDialog.Builder(service)
                            .setTitle("Download Selesai")
                            .setMessage("Download selesai. Pembaruan ke versi " .. remoteVersion .. " telah berhasil dipasang.")
                            .setPositiveButton("Oke", function(d)
                              d.dismiss()
                            end)
                          displayOverlayDialog(doneBuilder)
                          service.speak("Download selesai. Pembaruan berhasil dipasang.")
                        else
                          service.speak("Gagal menyimpan pembaruan ke berkas lokal.")
                        end
                      end
                    })
                  end
                }).start()
              end)
              .setNegativeButton("Nanti", function(dlg)
                dlg.dismiss()
              end)

            displayOverlayDialog(builder)
            service.speak("Versi baru tersedia: " .. remoteVersion .. ". Fungsi: " .. remoteDesc)

          elseif isManual then
            if checkSuccess then
              local noUpdateBuilder = AlertDialog.Builder(service)
                .setTitle("Periksa Versi")
                .setMessage("Tidak ada pembaruan.\n\nAnda sudah menggunakan versi terbaru (" .. SCRIPT_VERSION .. ").")
                .setPositiveButton("Oke", function(dlg)
                  dlg.dismiss()
                end)
              displayOverlayDialog(noUpdateBuilder)
              service.speak("Tidak ada pembaruan. Anda sudah menggunakan versi terbaru.")
            else
              local errorBuilder = AlertDialog.Builder(service)
                .setTitle("Periksa Versi")
                .setMessage("Gagal memeriksa versi baru. Pastikan koneksi internet Anda aktif dan dapat mengakses server.")
                .setPositiveButton("Oke", function(dlg)
                  dlg.dismiss()
                end)
              displayOverlayDialog(errorBuilder)
              service.speak("Gagal memeriksa versi baru. Pastikan koneksi internet Anda aktif.")
            end
          end
        end
      })
    end
  }).start()
end

-- Panduan suara responsif dan aman
local function speakGuidance(text, force)
  if isSettingsOpen or isRecordingVideo or currentMode == "video" then return end
  local now = System.currentTimeMillis()

  if not force then
    if text == lastSpeakText then
      if (now - lastSpeakTime < 1800) then
        return
      end
    else
      if (now - lastSpeakTime < 500) then
        return
      end
    end
  end

  lastSpeakTime = now
  lastSpeakText = text
  mainHandler.post(Runnable{
    run = function()
      pcall(function()
        if force then
          pcall(function() service.speak(0) end)
        end
        service.speak(text)
      end)
    end
  })
end

local function initCameraIds()
  if cachedFrontCamId >= 0 and cachedBackCamId >= 0 then return end
  pcall(function()
    local count = Camera.getNumberOfCameras()
    local info = Camera.CameraInfo()
    for i = 0, count - 1 do
      Camera.getCameraInfo(i, info)
      if info.facing == Camera.CameraInfo.CAMERA_FACING_FRONT and cachedFrontCamId < 0 then
        cachedFrontCamId = i
      elseif info.facing == Camera.CameraInfo.CAMERA_FACING_BACK and cachedBackCamId < 0 then
        cachedBackCamId = i
      end
    end
  end)
  if cachedFrontCamId < 0 then cachedFrontCamId = 0 end
  if cachedBackCamId < 0 then cachedBackCamId = 0 end
end

local function getCameraId(facingType)
  initCameraIds()
  return (facingType == "back") and cachedBackCamId or cachedFrontCamId
end

local function getSortedPictureSizes(params)
  local list = {}
  if not params then return list end
  local supported = params.getSupportedPictureSizes()
  if supported then
    for i = 0, supported.size() - 1 do
      local s = supported.get(i)
      table.insert(list, {
        width = s.width,
        height = s.height,
        pixels = s.width * s.height
      })
    end
    table.sort(list, function(a, b)
      return a.pixels > b.pixels
    end)
  end
  return list
end

local function getSortedVideoSizes(params)
  local list = {}
  if not params then return list end
  local supported = nil
  pcall(function()
    supported = params.getSupportedVideoSizes()
  end)
  if not supported or supported.size() == 0 then
    pcall(function()
      supported = params.getSupportedPreviewSizes()
    end)
  end
  if supported then
    for i = 0, supported.size() - 1 do
      local s = supported.get(i)
      table.insert(list, {
        width = s.width,
        height = s.height,
        pixels = s.width * s.height
      })
    end
    table.sort(list, function(a, b)
      return a.pixels < b.pixels
    end)
  end
  return list
end

local function applyFlashModeToParams(params)
  if not params then return end
  local supportedFlash = params.getSupportedFlashModes()
  if supportedFlash then
    local target = Camera.Parameters.FLASH_MODE_OFF
    if flashMode == "on" and supportedFlash.contains(Camera.Parameters.FLASH_MODE_ON) then
      target = Camera.Parameters.FLASH_MODE_ON
    elseif flashMode == "auto" and supportedFlash.contains(Camera.Parameters.FLASH_MODE_AUTO) then
      target = Camera.Parameters.FLASH_MODE_AUTO
    elseif flashMode == "off" and supportedFlash.contains(Camera.Parameters.FLASH_MODE_OFF) then
      target = Camera.Parameters.FLASH_MODE_OFF
    end
    params.setFlashMode(target)
  end
end

local function safeStartFaceDetection()
  if not cam or isSettingsOpen or currentMode ~= "photo" or isFaceDetectionActive then return end
  pcall(function()
    local p = cam.getParameters()
    if p and p.getMaxNumDetectedFaces() > 0 then
      cam.startFaceDetection()
      isFaceDetectionActive = true
    end
  end)
end

local function safeStopFaceDetection()
  if not cam or not isFaceDetectionActive then return end
  isFaceDetectionActive = false
  pcall(function()
    cam.stopFaceDetection()
  end)
end

local faceDetectionListener = Camera.FaceDetectionListener{
  onFaceDetection = function(faces, cameraInstance)
    processFaces(faces)
  end
}

local function releaseCamera()
  if isRecordingVideo then
    stopVideoRecording()
  end
  unregisterShakeListener()
  safeStopFaceDetection()
  if cam then
    local oldCam = cam
    cam = nil
    pcall(function()
      oldCam.setFaceDetectionListener(nil)
      oldCam.setPreviewCallback(nil)
      oldCam.stopPreview()
      oldCam.release()
    end)
  end
end

-- Menyiapkan kamera secara asinkron agar UI Thread tidak membeku (Anti-ANR / Anti-Restart)
local function startCameraPreview(holder)
  if not holder or isCameraOpening then return end
  isCameraOpening = true

  if tvStatus then
    tvStatus.setText("Sedang menyiapkan kamera...")
  end

  local camId = getCameraId(cameraFacing)
  local targetFacing = cameraFacing

  Thread(Runnable{
    run = function()
      -- Melepaskan kamera lama di background thread
      releaseCamera()
      pcall(function() Thread.sleep(30) end)

      -- Buka kamera di background thread agar tidak membekukan layanan aksesibilitas
      local openSuccess, newCam = pcall(function()
        return Camera.open(camId)
      end)

      mainHandler.post(Runnable{
        run = function()
          isCameraOpening = false

          if not openSuccess or not newCam then
            service.speak("Gagal membuka kamera " .. (targetFacing == "front" and "depan." or "belakang."))
            if tvStatus then tvStatus.setText("Gagal membuka kamera") end
            return
          end

          if not currentHolder or not dialog then
            pcall(function() newCam.release() end)
            return
          end

          cam = newCam

          pcall(function()
            cam.setDisplayOrientation(90)
            cam.setPreviewDisplay(holder)

            local params = cam.getParameters()
            if targetFacing == "front" then
              params.setRotation(270)
            else
              params.setRotation(90)
            end

            -- Fokus otomatis berkelanjutan (Sangat penting untuk kamera belakang)
            local supportedFocus = params.getSupportedFocusModes()
            if supportedFocus then
              if targetFacing == "back" and supportedFocus.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE) then
                params.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE)
              elseif supportedFocus.contains(Camera.Parameters.FOCUS_MODE_AUTO) then
                params.setFocusMode(Camera.Parameters.FOCUS_MODE_AUTO)
              end
            end

            -- Pemilihan resolusi foto terpisah per-kamera agar tidak memicu OOM pada kamera belakang
            local supportedSizes = getSortedPictureSizes(params)
            local curW, curH = getSavedPicSize(targetFacing)
            local isSizeValid = false
            if curW > 0 and curH > 0 then
              for _, sz in ipairs(supportedSizes) do
                if sz.width == curW and sz.height == curH then
                  isSizeValid = true
                  break
                end
              end
            end

            if isSizeValid then
              params.setPictureSize(curW, curH)
            elseif #supportedSizes > 0 then
              local chosen = nil
              -- Cari ukuran optimal (1.5 MP - 4 MP) agar kamera langsung aktif dalam hitungan milidetik
              for _, sz in ipairs(supportedSizes) do
                if sz.pixels <= 4000000 and sz.pixels >= 1500000 then
                  chosen = sz
                  break
                end
              end
              if not chosen then
                for _, sz in ipairs(supportedSizes) do
                  if sz.pixels <= 5000000 then
                    chosen = sz
                    break
                  end
                end
              end
              if not chosen then
                chosen = supportedSizes[#supportedSizes] -- Ukuran paling ringan yang tersedia
              end
              curW = chosen.width
              curH = chosen.height
              params.setPictureSize(curW, curH)
              savePicSize(targetFacing, curW, curH)
            end

            -- Resolusi pratinjau proporsional
            local previewSizes = params.getSupportedPreviewSizes()
            if previewSizes and previewSizes.size() > 0 then
              local targetRatio = curW / curH
              local chosenPreview = previewSizes.get(0)
              local minDiff = 999999
              for i = 0, previewSizes.size() - 1 do
                local ps = previewSizes.get(i)
                local curRatio = ps.width / ps.height
                local diff = math.abs(curRatio - targetRatio)
                if diff < minDiff or (math.abs(diff - minDiff) < 0.05 and ps.height == 720) then
                  minDiff = diff
                  chosenPreview = ps
                  if ps.height == 720 then break end
                end
              end
              params.setPreviewSize(chosenPreview.width, chosenPreview.height)
            end

            applyFlashModeToParams(params)
            cam.setParameters(params)
            cam.startPreview()

            wasFaceDetected = false
            lastNoFaceAlertTime = System.currentTimeMillis() - 1500
            lastSpeakTime = 0
            lastSpeakText = ""
            lastFaceProcessTime = 0

            if currentMode == "photo" then
              if tvStatus then
                tvStatus.setText("Mode Foto: Arahkan ke wajah")
              end
              local maxFaces = 0
              pcall(function() maxFaces = params.getMaxNumDetectedFaces() end)

              if maxFaces > 0 then
                cam.setFaceDetectionListener(faceDetectionListener)
                -- Jeda 350 ms agar frame sensor kamera stabil sebelum deteksi wajah aktif
                mainHandler.postDelayed(Runnable{
                  run = function()
                    if cam and not isSettingsOpen and currentMode == "photo" then
                      safeStartFaceDetection()
                    end
                  end
                }, 350)
                speakGuidance("Kamera " .. (targetFacing == "front" and "depan" or "belakang") .. " siap, arahkan ke wajah.", true)
              else
                service.speak("Sensor kamera " .. (targetFacing == "front" and "depan" or "belakang") .. " tidak mendukung deteksi wajah bawaan.")
              end
            else
              if tvStatus then
                tvStatus.setText("Mode Video aktif. Siap merekam.")
              end
            end
          end)
        end
      })
    end
  }).start()
end

local function resumeCameraAfterAction()
  isCapturing = false
  perfectStartTime = nil
  wasFaceDetected = false
  lastNoFaceAlertTime = System.currentTimeMillis() - 1500
  lastSpeakTime = 0
  lastSpeakText = ""
  lastFaceProcessTime = 0

  if currentMode == "photo" then
    pcall(function()
      if cam and not isSettingsOpen then
        cam.startPreview()
      end
    end)
    mainHandler.postDelayed(Runnable{
      run = function()
        if cam and not isSettingsOpen and currentMode == "photo" then
          safeStartFaceDetection()
        end
      end
    }, 200)
    if tvStatus then
      tvStatus.setText("Mode Foto: Arahkan ke wajah")
    end
    speakGuidance("Arahkan kembali ke wajah.", true)
  else
    if tvStatus then
      tvStatus.setText("Mode Video aktif. Siap merekam.")
    end
    service.speak("Kembali ke mode video. Siap merekam lagi.")
  end
end

-- Menampilkan pratinjau foto langsung di dalam skrip
local function showPhotoPreview(file, onClose)
  local bmp = decodeSampledBitmap(file.getAbsolutePath(), 1080, 1920)

  if not bmp then
    service.speak("Gagal memuat pratinjau foto.")
    onClose()
    return
  end

  local iv = ImageView(service)
  iv.setImageBitmap(bmp)
  iv.setAdjustViewBounds(true)
  iv.setContentDescription("Pratinjau foto " .. file.getName())

  local builder = AlertDialog.Builder(service)
    .setTitle("Pratinjau Foto")
    .setView(iv)
    .setPositiveButton("Kembali", function(dlg)
      dlg.dismiss()
      pcall(function() bmp.recycle() end)
      onClose()
    end)
    .setCancelable(false)

  displayOverlayDialog(builder)
  service.speak("Menampilkan pratinjau foto. Tekan tombol Kembali untuk kembali ke menu.")
end

-- Memutar video langsung di dalam skrip
local function showVideoPreview(file, onClose)
  local videoView = VideoView(service)
  local mediaController = MediaController(service)
  mediaController.setAnchorView(videoView)
  videoView.setMediaController(mediaController)

  local ok = pcall(function()
    videoView.setVideoPath(file.getAbsolutePath())
  end)

  if not ok then
    service.speak("Gagal memuat video.")
    onClose()
    return
  end

  local vParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 700)
  videoView.setLayoutParams(vParams)

  local builder = AlertDialog.Builder(service)
    .setTitle("Putar Video")
    .setView(videoView)
    .setPositiveButton("Kembali", function(dlg)
      pcall(function() videoView.stopPlayback() end)
      dlg.dismiss()
      onClose()
    end)
    .setCancelable(false)

  displayOverlayDialog(builder)
  pcall(function() videoView.start() end)
  service.speak("Memutar video. Tekan tombol Kembali untuk kembali ke menu.")
end

-- Membagikan berkas foto/video tanpa kendala sistem
local function shareMediaFile(file, isVideo)
  if not file or not file.exists() then
    service.speak("Berkas tidak ditemukan.")
    return
  end

  scanMediaFile(file)
  isSharingAction = true

  if dialog then
    pcall(function()
      dialog.dismiss()
    end)
  end

  mainHandler.postDelayed(Runnable{
    run = function()
      local shareUri = getShareableUri(file, isVideo)

      if not shareUri then
        service.speak("Gagal menyiapkan tautan berkas.")
        return
      end

      local mimeType = isVideo and "video/mp4" or "image/jpeg"
      local shareSuccess = false

      local intent = Intent(Intent.ACTION_SEND)
      intent.setType(mimeType)
      intent.putExtra(Intent.EXTRA_STREAM, shareUri)
      intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

      pcall(function()
        local chooserTitle = "Bagikan " .. (isVideo and "Video" or "Foto")
        local chooser = Intent.createChooser(intent, chooserTitle)
        chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        service.startActivity(chooser)
        shareSuccess = true
      end)

      if not shareSuccess then
        pcall(function()
          service.startActivity(intent)
          shareSuccess = true
        end)
      end

      if shareSuccess then
        service.speak("Membuka menu bagikan...")
      else
        service.speak("Gagal membuka menu bagikan.")
      end
    end
  }, 120)
end

-- Dialog ubah nama berkas
local function showRenameDialog(file, isVideo, onDone)
  local et = EditText(service)
  local originalName = file.getName()
  local dotIdx = originalName:find("%.[^%.]*$")
  local baseName = dotIdx and originalName:sub(1, dotIdx - 1) or originalName
  local ext = dotIdx and originalName:sub(dotIdx) or ""
  et.setText(baseName)
  pcall(function() et.setSelection(#baseName) end)

  local builder = AlertDialog.Builder(service)
    .setTitle("Ubah Nama " .. (isVideo and "Video" or "Foto"))
    .setView(et)
    .setPositiveButton("Simpan", function(dlg)
      dlg.dismiss()
      local newBase = tostring(et.getText().toString())
      if newBase == nil or newBase == "" then
        service.speak("Nama tidak boleh kosong. Nama tidak diubah.")
        onDone(file)
        return
      end
      local newFile = File(file.getParentFile(), newBase .. ext)
      local ok = false
      pcall(function()
        ok = file.renameTo(newFile)
      end)
      if ok then
        scanMediaFile(newFile)
        service.speak("Nama berhasil diubah.")
        onDone(newFile)
      else
        service.speak("Gagal mengubah nama berkas. Nama tidak diubah.")
        onDone(file)
      end
    end)
    .setNegativeButton("Batal", function(dlg)
      dlg.dismiss()
      onDone(file)
    end)

  displayOverlayDialog(builder)
end

-- Menu tindakan setelah foto/video tersimpan
showMediaResultDialog = function(file, isVideo)
  local currentFile = file

  local function deleteThis()
    local builder = AlertDialog.Builder(service)
      .setTitle("Hapus " .. (isVideo and "Video" or "Foto"))
      .setMessage("Apakah Anda yakin ingin menghapus " .. currentFile.getName() .. "?")
      .setPositiveButton("Hapus", function(dlg)
        dlg.dismiss()
        local ok = false
        pcall(function() ok = currentFile.delete() end)
        if ok then
          service.speak((isVideo and "Video" or "Foto") .. " berhasil dihapus.")
          resumeCameraAfterAction()
        else
          service.speak("Gagal menghapus berkas.")
          showMediaResultDialog(currentFile, isVideo)
        end
      end)
      .setNegativeButton("Batal", function(dlg)
        dlg.dismiss()
        showMediaResultDialog(currentFile, isVideo)
      end)
    displayOverlayDialog(builder)
  end

  local function renameThis()
    showRenameDialog(currentFile, isVideo, function(resultFile)
      currentFile = resultFile
      showMediaResultDialog(currentFile, isVideo)
    end)
  end

  local items = {
    isVideo and "Putar Video" or "Buka",
    "Bagikan",
    "Hapus",
    "Ubah Nama",
    "Kembali"
  }

  local builder = AlertDialog.Builder(service)
    .setTitle((isVideo and "Video Tersimpan: " or "Foto Tersimpan: ") .. currentFile.getName())
    .setItems(items, function(dlg, which)
      dlg.dismiss()
      if which == 0 then
        if isVideo then
          showVideoPreview(currentFile, function()
            showMediaResultDialog(currentFile, isVideo)
          end)
        else
          showPhotoPreview(currentFile, function()
            showMediaResultDialog(currentFile, isVideo)
          end)
        end
      elseif which == 1 then
        shareMediaFile(currentFile, isVideo)
      elseif which == 2 then
        deleteThis()
      elseif which == 3 then
        renameThis()
      elseif which == 4 then
        resumeCameraAfterAction()
      end
    end)
    .setCancelable(false)

  displayOverlayDialog(builder)
  service.speak((isVideo and "Video berhasil disimpan. " or "Foto berhasil disimpan. ") .. "Pilih tindakan: " .. (isVideo and "putar video" or "buka") .. ", bagikan, hapus, ubah nama, atau kembali.")
end

-- Penghentian video aman
stopVideoRecording = function()
  if not isRecordingVideo then return end

  local recordedTime = System.currentTimeMillis() - videoStartTime
  if recordedTime < 1000 then
    mainHandler.postDelayed(Runnable{
      run = function()
        stopVideoRecording()
      end
    }, 1000 - recordedTime)
    return
  end

  isRecordingVideo = false
  unregisterShakeListener()
  triggerVibrate(150)

  pcall(function()
    if mediaRecorder then
      mediaRecorder.stop()
      mediaRecorder.reset()
      mediaRecorder.release()
      mediaRecorder = nil
    end
  end)

  pcall(function()
    if cam then
      cam.lock()
    end
  end)

  if lastVideoFile then
    scanMediaFile(lastVideoFile)
  end

  mainHandler.post(Runnable{
    run = function()
      if btnStopRecord then
        btnStopRecord.setVisibility(View.GONE)
      end
      if btnRecordVideo then
        btnRecordVideo.setVisibility(View.VISIBLE)
        btnRecordVideo.setText("Mulai Rekam Video")
        btnRecordVideo.setBackgroundColor(Color.parseColor("#16A34A"))
        pcall(function()
          btnRecordVideo.requestFocus()
          btnRecordVideo.sendAccessibilityEvent(32768)
        end)
      end
      if tvStatus then
        tvStatus.setText("Video berhasil disimpan")
      end
      if lastVideoFile then
        showMediaResultDialog(lastVideoFile, true)
      else
        service.speak("Rekaman video selesai dan berhasil disimpan.")
      end
    end
  })
end

startVideoRecording = function()
  if isRecordingVideo or not cam or isCapturing or isSettingsOpen then return end

  safeStopFaceDetection()

  local startSuccess = false
  pcall(function()
    cam.unlock()
    mediaRecorder = MediaRecorder()
    mediaRecorder.setCamera(cam)
    mediaRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
    mediaRecorder.setVideoSource(MediaRecorder.VideoSource.CAMERA)

    mediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
    mediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
    mediaRecorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264)

    if cameraFacing == "front" then
      mediaRecorder.setOrientationHint(270)
    else
      mediaRecorder.setOrientationHint(90)
    end

    if selectedVideoWidth > 0 and selectedVideoHeight > 0 then
      pcall(function()
        mediaRecorder.setVideoSize(selectedVideoWidth, selectedVideoHeight)
      end)
    end

    local dir = File("/sdcard/" .. SCRIPT_TITLE)
    if not dir.exists() then dir.mkdirs() end
    local nowStr = os.date("%Y%m%d_%H%M%S")
    local videoFile = File(dir, "Video_" .. cameraFacing .. "_" .. nowStr .. ".mp4")
    lastVideoFile = videoFile

    mediaRecorder.setOutputFile(videoFile.getAbsolutePath())
    mediaRecorder.setPreviewDisplay(currentHolder.getSurface())

    mediaRecorder.prepare()
    mediaRecorder.start()
    videoStartTime = System.currentTimeMillis()
    startSuccess = true
  end)

  if startSuccess then
    isRecordingVideo = true
    if shakeStopEnabled then
      registerShakeListener()
    end
    triggerVibrate(100)

    if btnRecordVideo then
      btnRecordVideo.setVisibility(View.GONE)
    end
    if btnStopRecord then
      btnStopRecord.setVisibility(View.VISIBLE)
    end
    if tvStatus then
      tvStatus.setText("Sedang merekam video... Tekan tombol Berhenti" .. (shakeStopEnabled and " atau goyangkan HP" or ""))
    end

    -- Pindahkan kursor pembaca layar langsung dan terkunci ke tombol Berhenti Rekam Video
    mainHandler.postDelayed(Runnable{
      run = function()
        pcall(function()
          if btnStopRecord and isRecordingVideo then
            btnStopRecord.setFocusable(true)
            btnStopRecord.requestFocus()
            btnStopRecord.sendAccessibilityEvent(8)
            btnStopRecord.sendAccessibilityEvent(32768)
            btnStopRecord.performAccessibilityAction(64, nil)
          end
        end)
      end
    }, 150)

    mainHandler.postDelayed(Runnable{
      run = function()
        pcall(function()
          if btnStopRecord and isRecordingVideo then
            btnStopRecord.sendAccessibilityEvent(32768)
            btnStopRecord.performAccessibilityAction(64, nil)
          end
        end)
      end
    }, 400)

    service.speak("Mulai merekam video.")
  else
    lastVideoFile = nil
    pcall(function()
      if mediaRecorder then
        mediaRecorder.release()
        mediaRecorder = nil
      end
      if cam then
        cam.lock()
      end
    end)
    service.speak("Gagal memulai perekaman video. Pastikan izin mikrofon telah diizinkan.")
  end
end

takeSelfiePhoto = function()
  if not cam or isCapturing or isSettingsOpen or currentMode ~= "photo" then return end
  isCapturing = true

  safeStopFaceDetection()

  triggerVibrate(80)
  playShutterSound()

  pcall(function()
    cam.takePicture(
      Camera.ShutterCallback{
        onShutter = function()
          triggerVibrate(60)
        end
      },
      nil,
      Camera.PictureCallback{
        onPictureTaken = function(data, camera)
          local nowStr = os.date("%Y%m%d_%H%M%S")
          local dir = File("/sdcard/" .. SCRIPT_TITLE)
          if not dir.exists() then dir.mkdirs() end
          local photoFile = File(dir, "Foto_" .. cameraFacing .. "_" .. nowStr .. ".jpg")

          local success = false
          pcall(function()
            local fos = FileOutputStream(photoFile)
            fos.write(data)
            fos.flush()
            fos.close()
            success = true
            scanMediaFile(photoFile)
          end)

          mainHandler.post(Runnable{
            run = function()
              if success then
                triggerVibrate(120)
                isCapturing = false
                showMediaResultDialog(photoFile, false)
              else
                service.speak("Gagal menyimpan berkas foto.")
                mainHandler.postDelayed(Runnable{
                  run = function()
                    resumeCameraAfterAction()
                  end
                }, 1500)
              end
            end
          })
        end
      }
    )
  end)
end

-- Deteksi wajah responsif dan lancar
processFaces = function(faces)
  if isCapturing or isSettingsOpen or currentMode ~= "photo" or not faces then return end

  local now = System.currentTimeMillis()
  if (now - lastFaceProcessTime) < 60 then return end
  lastFaceProcessTime = now

  local count = 0
  pcall(function()
    count = Array.getLength(faces)
  end)
  if count == 0 then
    pcall(function() count = faces.length end)
  end
  if count == 0 then
    pcall(function() count = #faces end)
  end

  if count == 0 then
    perfectStartTime = nil
    if wasFaceDetected then
      wasFaceDetected = false
      lastNoFaceAlertTime = now
      speakGuidance("Wajah terlepas", true)
    elseif (now - lastNoFaceAlertTime >= 2200) then
      lastNoFaceAlertTime = now
      speakGuidance("Wajah belum terlihat", false)
    end
    return
  end

  wasFaceDetected = true

  local face = nil
  pcall(function() face = Array.get(faces, 0) end)
  if not face then
    pcall(function() face = faces[0] end)
  end
  if not face then
    pcall(function() face = faces[1] end)
  end

  if not face or not face.rect then return end

  local r = face.rect
  local left, top, right, bottom = 0, 0, 0, 0
  pcall(function()
    left = r.left
    top = r.top
    right = r.right
    bottom = r.bottom
  end)

  local cx = (left + right) / 2
  local cy = (top + bottom) / 2
  local faceW = right - left
  local faceH = bottom - top
  local faceSize = math.max(faceW, faceH)

  local screenX = 0
  local screenY = -cx

  if cameraFacing == "front" then
    screenX = -cy
  else
    screenX = cy
  end

  local horizontalGuide = ""
  local verticalGuide = ""
  local distanceGuide = ""

  if screenX < -250 then
    horizontalGuide = "Kurang ke kanan"
  elseif screenX > 250 then
    horizontalGuide = "Kurang ke kiri"
  end

  if screenY < -270 then
    verticalGuide = "Kurang ke bawah"
  elseif screenY > 270 then
    verticalGuide = "Kurang ke atas"
  end

  if faceSize < 400 then
    distanceGuide = "Dekatkan ponsel"
  elseif faceSize > 1250 then
    distanceGuide = "Jauhkan sedikit"
  end

  local isCentered = (horizontalGuide == "") and (verticalGuide == "") and (distanceGuide == "")

  if not isCentered then
    perfectStartTime = nil
    local instruction = horizontalGuide
    if instruction == "" then instruction = verticalGuide end
    if instruction == "" then instruction = distanceGuide end
    speakGuidance(instruction, false)
  else
    if not perfectStartTime then
      perfectStartTime = System.currentTimeMillis()
      speakGuidance("Pas, tahan", true)
      triggerVibrate(40)
    else
      local heldTime = System.currentTimeMillis() - perfectStartTime
      if heldTime >= HOLD_DURATION then
        takeSelfiePhoto()
      end
    end
  end
end

showCameraSelectionDialog = function()
  local options = {
    "Kamera Depan (Selfie)",
    "Kamera Belakang"
  }
  local selectedIndex = (cameraFacing == "back") and 1 or 0

  local builder = AlertDialog.Builder(service)
    .setTitle("Pilih Kamera")
    .setSingleChoiceItems(options, selectedIndex, function(dlg, which)
      dlg.dismiss()
      local targetFacing = (which == 0) and "front" or "back"
      if targetFacing == cameraFacing then return end

      cameraFacing = targetFacing
      sp.edit().putString("camera_facing", cameraFacing).apply()

      if btnSwitchCam then
        btnSwitchCam.setText((cameraFacing == "front") and "Kamera: Depan" or "Kamera: Belakang")
      end

      service.speak("Beralih ke " .. (which == 0 and "Kamera Depan." or "Kamera Belakang."))

      if currentHolder then
        startCameraPreview(currentHolder)
      end
    end)
    .setNegativeButton("Batal", nil)

  displayOverlayDialog(builder)
end

local function showResolutionDialog()
  if not cam then
    service.speak("Kamera belum siap.")
    return
  end

  local params = nil
  pcall(function() params = cam.getParameters() end)
  if not params then return end

  local sizes = getSortedPictureSizes(params)
  if #sizes == 0 then
    service.speak("Daftar resolusi tidak tersedia.")
    return
  end

  local curW, curH = getSavedPicSize(cameraFacing)
  local options = {}
  local selectedIndex = 0

  for idx, s in ipairs(sizes) do
    local mp = string.format("%.1f MP", s.pixels / 1000000)
    table.insert(options, s.width .. " x " .. s.height .. " (" .. mp .. ")")
    if s.width == curW and s.height == curH then
      selectedIndex = idx - 1
    end
  end

  local builder = AlertDialog.Builder(service)
    .setTitle("Resolusi Foto (" .. (cameraFacing == "front" and "Depan" or "Belakang") .. ")")
    .setSingleChoiceItems(options, selectedIndex, function(dlg, which)
      dlg.dismiss()
      local chosen = sizes[which + 1]
      savePicSize(cameraFacing, chosen.width, chosen.height)

      pcall(function()
        local p = cam.getParameters()
        p.setPictureSize(chosen.width, chosen.height)
        cam.setParameters(p)
      end)

      local mp = string.format("%.1f Megapixel", chosen.pixels / 1000000)
      service.speak("Resolusi foto diatur ke " .. chosen.width .. " kali " .. chosen.height .. ", " .. mp)
    end)
    .setNegativeButton("Batal", nil)

  displayOverlayDialog(builder)
end

local function showVideoResolutionDialog()
  if not cam then
    service.speak("Kamera belum siap.")
    return
  end

  local params = nil
  pcall(function() params = cam.getParameters() end)
  if not params then return end

  local sizes = getSortedVideoSizes(params)
  if #sizes == 0 then
    service.speak("Daftar resolusi video tidak tersedia.")
    return
  end

  local options = {}
  local selectedIndex = 0

  for idx, s in ipairs(sizes) do
    local mp = string.format("%.1f MP", s.pixels / 1000000)
    local is720p = (s.width == 1280 and s.height == 720) or (s.width == 720 and s.height == 1280)
    local label = s.width .. " x " .. s.height .. " (" .. mp .. (is720p and ", 720p Bawaan" or "") .. ")"
    table.insert(options, label)
    if s.width == selectedVideoWidth and s.height == selectedVideoHeight then
      selectedIndex = idx - 1
    end
  end

  local builder = AlertDialog.Builder(service)
    .setTitle("Pilih Resolusi Video")
    .setSingleChoiceItems(options, selectedIndex, function(dlg, which)
      dlg.dismiss()
      local chosen = sizes[which + 1]
      selectedVideoWidth = chosen.width
      selectedVideoHeight = chosen.height
      sp.edit().putInt("video_width", selectedVideoWidth).putInt("video_height", selectedVideoHeight).apply()

      local mp = string.format("%.1f Megapixel", chosen.pixels / 1000000)
      service.speak("Resolusi video diatur ke " .. chosen.width .. " kali " .. chosen.height .. ", " .. mp)
    end)
    .setNegativeButton("Batal", nil)

  displayOverlayDialog(builder)
end

local function showShakeSensitivityDialog()
  local options = {
    "Tinggi (Goyangan Ringan)",
    "Sedang (Goyangan Normal - Bawaan)",
    "Rendah (Goyangan Kuat)"
  }
  local values = { 14, 22, 32 }
  local selectedIndex = 1

  for idx, val in ipairs(values) do
    if val == shakeSensitivity then
      selectedIndex = idx - 1
      break
    end
  end

  local builder = AlertDialog.Builder(service)
    .setTitle("Sensitivitas Goyang Stop Video")
    .setSingleChoiceItems(options, selectedIndex, function(dlg, which)
      dlg.dismiss()
      shakeSensitivity = values[which + 1]
      sp.edit().putInt("shake_sensitivity", shakeSensitivity).apply()
      service.speak("Sensitivitas goyang diatur ke " .. options[which + 1] .. ".")
    end)
    .setNegativeButton("Batal", nil)

  displayOverlayDialog(builder)
end

local function showFlashModeDialog()
  local options = {
    "Tidak Aktif (Mati)",
    "Aktif",
    "Otomatis"
  }
  local values = { "off", "on", "auto" }
  local selectedIndex = 0

  for idx, v in ipairs(values) do
    if v == flashMode then
      selectedIndex = idx - 1
      break
    end
  end

  local builder = AlertDialog.Builder(service)
    .setTitle("Lampu Kamera (Flash)")
    .setSingleChoiceItems(options, selectedIndex, function(dlg, which)
      dlg.dismiss()
      flashMode = values[which + 1]
      sp.edit().putString("camera_flash_mode", flashMode).apply()

      local applied = false
      if cam then
        pcall(function()
          local p = cam.getParameters()
          local supportedFlash = p.getSupportedFlashModes()
          if supportedFlash then
            applyFlashModeToParams(p)
            cam.setParameters(p)
            applied = true
          end
        end)
      end

      if applied or (cam == nil) then
        service.speak("Lampu kamera diatur ke " .. options[which + 1] .. ".")
      else
        service.speak("Lampu kamera diatur ke " .. options[which + 1] .. ", namun sensor kamera saat ini tidak mendukung flash.")
      end
    end)
    .setNegativeButton("Batal", nil)

  displayOverlayDialog(builder)
end

local function showHoldTimeDialog()
  local options = {
    "1 Detik (Cepat)",
    "1.5 Detik (Sedang - Bawaan)",
    "2 Detik (Santai)",
    "3 Detik (Lama)"
  }
  local values = { 1000, 1500, 2000, 3000 }
  local selectedIndex = 0

  for idx, val in ipairs(values) do
    if val == HOLD_DURATION then
      selectedIndex = idx - 1
      break
    end
  end

  local builder = AlertDialog.Builder(service)
    .setTitle("Waktu Tahan Sebelum Potret")
    .setSingleChoiceItems(options, selectedIndex, function(dlg, which)
      dlg.dismiss()
      HOLD_DURATION = values[which + 1]
      sp.edit().putInt("hold_duration", HOLD_DURATION).apply()
      service.speak("Waktu tahan diatur ke " .. (HOLD_DURATION / 1000) .. " detik.")
    end)
    .setNegativeButton("Batal", nil)

  displayOverlayDialog(builder)
end

local function showResetConfirmationDialog()
  local builder = AlertDialog.Builder(service)
    .setTitle("Reset Pengaturan")
    .setMessage("Apakah Anda yakin ingin mengembalikan semua pengaturan kamera ke setelan awal?")
    .setPositiveButton("Reset", function(dlg)
      dlg.dismiss()

      sp.edit().clear().apply()

      cameraFacing = "front"
      HOLD_DURATION = 1000
      vibrationEnabled = true
      shutterSoundEnabled = true
      shakeStopEnabled = true
      flashMode = "off"
      selectedVideoWidth = 1280
      selectedVideoHeight = 720
      shakeSensitivity = 22
      wasFaceDetected = false
      lastSpeakText = ""
      lastSpeakTime = 0

      if btnSwitchCam then
        btnSwitchCam.setText("Kamera: Depan")
      end

      if currentHolder then
        startCameraPreview(currentHolder)
      end

      service.speak("Pengaturan berhasil direset ke setelan awal.")
    end)
    .setNegativeButton("Batal", nil)

  displayOverlayDialog(builder)
end

local function showSettingsMenu()
  isSettingsOpen = true
  perfectStartTime = nil
  safeStopFaceDetection()

  local curCamText = (cameraFacing == "front") and "Depan" or "Belakang"
  local vibStatus = vibrationEnabled and "Aktif" or "Mati"
  local soundStatus = shutterSoundEnabled and "Aktif" or "Mati"
  local shakeStopStatus = shakeStopEnabled and "Aktif" or "Mati"
  local holdSec = string.format("%.1f", HOLD_DURATION / 1000)
  local curW, curH = getSavedPicSize(cameraFacing)
  local resText = (curW > 0 and curH > 0) and (curW .. "x" .. curH) or "Otomatis Optimal"
  local videoResText = (selectedVideoWidth > 0 and selectedVideoHeight > 0) and (selectedVideoWidth .. "x" .. selectedVideoHeight) or "1280x720 (720p)"

  local shakeText = "Sedang"
  if shakeSensitivity <= 14 then
    shakeText = "Tinggi (Ringan)"
  elseif shakeSensitivity >= 32 then
    shakeText = "Rendah (Kuat)"
  end

  local flashText = "Tidak Aktif"
  if flashMode == "on" then
    flashText = "Aktif"
  elseif flashMode == "auto" then
    flashText = "Otomatis"
  end

  local items = {
    "1. Pilihan Kamera (Aktif: Kamera " .. curCamText .. ")",
    "2. Resolusi Foto (" .. resText .. ")",
    "3. Resolusi Video (" .. videoResText .. ")",
    "4. Sensitivitas Goyang Stop Video (" .. shakeText .. ")",
    "5. Goyangkan untuk Berhenti Rekam (" .. shakeStopStatus .. ")",
    "6. Lampu Kamera / Flash (" .. flashText .. ")",
    "7. Waktu Tahan Jepret (" .. holdSec .. " detik)",
    "8. Suara Jepret Kamera (" .. soundStatus .. ")",
    "9. Getaran (" .. vibStatus .. ")",
    "10. Periksa Versi Baru",
    "11. Reset Pengaturan"
  }

  local builder = AlertDialog.Builder(service)
    .setTitle(SCRIPT_TITLE .. " " .. SCRIPT_VERSION)
    .setItems(items, function(dlg, which)
      dlg.dismiss()
      if which == 0 then
        showCameraSelectionDialog()
      elseif which == 1 then
        showResolutionDialog()
      elseif which == 2 then
        showVideoResolutionDialog()
      elseif which == 3 then
        showShakeSensitivityDialog()
      elseif which == 4 then
        shakeStopEnabled = not shakeStopEnabled
        sp.edit().putBoolean("shake_stop_enabled", shakeStopEnabled).apply()
        if not shakeStopEnabled then
          unregisterShakeListener()
        elseif isRecordingVideo then
          registerShakeListener()
        end
        service.speak("Goyangkan untuk berhenti merekam video " .. (shakeStopEnabled and "diaktifkan." or "dinonaktifkan."))
      elseif which == 5 then
        showFlashModeDialog()
      elseif which == 6 then
        showHoldTimeDialog()
      elseif which == 7 then
        shutterSoundEnabled = not shutterSoundEnabled
        sp.edit().putBoolean("shutter_sound_enabled", shutterSoundEnabled).apply()
        service.speak("Suara jepret kamera " .. (shutterSoundEnabled and "diaktifkan." or "dinonaktifkan."))
      elseif which == 8 then
        vibrationEnabled = not vibrationEnabled
        sp.edit().putBoolean("vibration_enabled", vibrationEnabled).apply()
        service.speak("Getaran " .. (vibrationEnabled and "diaktifkan." or "dinonaktifkan."))
      elseif which == 9 then
        checkUpdateWithDialog(true)
      elseif which == 10 then
        showResetConfirmationDialog()
      end
    end)
    .setNegativeButton("Tutup", function(dlg)
      dlg.dismiss()
    end)

  local settingsDialog = displayOverlayDialog(builder)
  settingsDialog.setOnDismissListener(DialogInterface.OnDismissListener{
    onDismiss = function()
      isSettingsOpen = false
      if cam and not isCapturing and currentMode == "photo" then
        safeStartFaceDetection()
        service.speak("Kamera aktif kembali.")
      end
    end
  })
end

local function toggleCameraMode()
  if isRecordingVideo then
    service.speak("Hentikan rekaman terlebih dahulu.")
    return
  end

  if currentMode == "photo" then
    currentMode = "video"
    btnMode.setText("Mode: Video")
    btnMode.setBackgroundColor(Color.parseColor("#7C3AED"))
    btnRecordVideo.setVisibility(View.VISIBLE)
    if btnStopRecord then btnStopRecord.setVisibility(View.GONE) end
    tvStatus.setText("Mode Video aktif. Siap merekam.")
    safeStopFaceDetection()
    service.speak("Beralih ke mode video. Tekan tombol mulai rekam video.")
  else
    currentMode = "photo"
    btnMode.setText("Mode: Foto")
    btnMode.setBackgroundColor(Color.parseColor("#0284C7"))
    btnRecordVideo.setVisibility(View.GONE)
    if btnStopRecord then btnStopRecord.setVisibility(View.GONE) end
    tvStatus.setText("Mode Foto: Arahkan ke wajah")
    if cam and not isSettingsOpen then
      safeStartFaceDetection()
    end
    service.speak("Beralih ke mode foto. Arahkan kamera ke wajah.")
  end
end

local function launchCamera()
  local initialCamName = (cameraFacing == "front") and "depan" or "belakang"
  service.speak("Membuka kamera " .. initialCamName .. "...")

  local surfaceView = SurfaceView(service)
  surfaceView.setLayoutParams(ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
  surfaceView.setZOrderMediaOverlay(true)
  surfaceView.getHolder().setKeepScreenOn(true)

  surfaceView.setFocusable(false)
  surfaceView.setClickable(false)
  pcall(function()
    surfaceView.setImportantForAccessibility(2)
  end)

  local holder = surfaceView.getHolder()
  holder.addCallback(SurfaceHolder.Callback{
    surfaceCreated = function(h)
      currentHolder = h
      startCameraPreview(h)
    end,
    surfaceChanged = function(h, format, w, hgt) end,
    surfaceDestroyed = function(h)
      currentHolder = nil
      releaseCamera()
    end
  })

  frame = FrameLayout(service)
  frame.setLayoutParams(ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
  frame.setFitsSystemWindows(true)
  frame.addView(surfaceView)

  -- Status Atas
  tvStatus = TextView(service)
  tvStatus.setText("Kamera aktif (Mode Foto)")
  tvStatus.setContentDescription("Kamera aktif (Mode Foto)")
  tvStatus.setTextSize(17)
  tvStatus.setTextColor(Color.WHITE)
  tvStatus.setBackgroundColor(Color.parseColor("#99000000"))
  tvStatus.setPadding(28, 22, 28, 22)
  tvStatus.setGravity(Gravity.CENTER)
  tvStatus.setFocusable(true)

  local tvParams = FrameLayout.LayoutParams(
    ViewGroup.LayoutParams.MATCH_PARENT,
    ViewGroup.LayoutParams.WRAP_CONTENT,
    Gravity.TOP
  )
  tvStatus.setLayoutParams(tvParams)
  frame.addView(tvStatus)

  -- Tombol Mulai Rekam Video
  btnRecordVideo = Button(service)
  btnRecordVideo.setText("Mulai Rekam Video")
  btnRecordVideo.setContentDescription("Mulai Rekam Video, tombol")
  btnRecordVideo.setTextSize(17)
  btnRecordVideo.setTextColor(Color.WHITE)
  btnRecordVideo.setBackgroundColor(Color.parseColor("#16A34A"))
  btnRecordVideo.setPadding(20, 18, 20, 18)
  btnRecordVideo.setFocusable(true)
  btnRecordVideo.setVisibility(View.GONE)

  local recordParams = FrameLayout.LayoutParams(
    ViewGroup.LayoutParams.MATCH_PARENT,
    ViewGroup.LayoutParams.WRAP_CONTENT,
    Gravity.BOTTOM
  )
  recordParams.setMargins(24, 0, 24, 86)
  btnRecordVideo.setLayoutParams(recordParams)

  btnRecordVideo.setOnClickListener(function()
    startVideoRecording()
  end)
  frame.addView(btnRecordVideo)

  -- Tombol Berhenti Rekam Video
  btnStopRecord = Button(service)
  btnStopRecord.setText("Berhenti Rekam Video")
  btnStopRecord.setContentDescription("Berhenti Rekam Video, tombol")
  btnStopRecord.setTextSize(17)
  btnStopRecord.setTextColor(Color.WHITE)
  btnStopRecord.setBackgroundColor(Color.parseColor("#DC2626"))
  btnStopRecord.setPadding(20, 18, 20, 18)
  btnStopRecord.setFocusable(true)
  btnStopRecord.setVisibility(View.GONE)

  local stopParams = FrameLayout.LayoutParams(
    ViewGroup.LayoutParams.MATCH_PARENT,
    ViewGroup.LayoutParams.WRAP_CONTENT,
    Gravity.BOTTOM
  )
  stopParams.setMargins(24, 0, 24, 86)
  btnStopRecord.setLayoutParams(stopParams)

  btnStopRecord.setOnClickListener(function()
    stopVideoRecording()
  end)
  frame.addView(btnStopRecord)

  -- Bilah Menu Bawah
  local bottomControlBar = LinearLayout(service)
  bottomControlBar.setOrientation(LinearLayout.HORIZONTAL)
  bottomControlBar.setBackgroundColor(Color.parseColor("#CC000000"))
  bottomControlBar.setPadding(12, 12, 12, 12)

  local barParams = FrameLayout.LayoutParams(
    ViewGroup.LayoutParams.MATCH_PARENT,
    ViewGroup.LayoutParams.WRAP_CONTENT,
    Gravity.BOTTOM
  )
  bottomControlBar.setLayoutParams(barParams)

  -- 1. Mode Foto / Video
  btnMode = Button(service)
  btnMode.setText("Mode: Foto")
  btnMode.setTextSize(13)
  btnMode.setTextColor(Color.WHITE)
  btnMode.setBackgroundColor(Color.parseColor("#0284C7"))
  btnMode.setPadding(0, 12, 0, 12)

  local modeParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1)
  modeParams.setMargins(0, 0, 4, 0)
  btnMode.setLayoutParams(modeParams)

  btnMode.setOnClickListener(function()
    toggleCameraMode()
  end)

  -- 2. Pemilih Kamera Depan / Belakang
  btnSwitchCam = Button(service)
  local initialCamText = (cameraFacing == "front") and "Kamera: Depan" or "Kamera: Belakang"
  btnSwitchCam.setText(initialCamText)
  btnSwitchCam.setTextSize(13)
  btnSwitchCam.setTextColor(Color.WHITE)
  btnSwitchCam.setBackgroundColor(Color.parseColor("#4F46E5"))
  btnSwitchCam.setPadding(0, 12, 0, 12)

  local switchParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1)
  switchParams.setMargins(2, 0, 2, 0)
  btnSwitchCam.setLayoutParams(switchParams)

  btnSwitchCam.setOnClickListener(function()
    if isRecordingVideo then
      service.speak("Hentikan rekaman video terlebih dahulu.")
      return
    end
    showCameraSelectionDialog()
  end)

  -- 3. Pengaturan
  local btnSettings = Button(service)
  btnSettings.setText("Pengaturan")
  btnSettings.setTextSize(13)
  btnSettings.setTextColor(Color.WHITE)
  btnSettings.setBackgroundColor(Color.parseColor("#2563EB"))
  btnSettings.setPadding(0, 12, 0, 12)

  local settingsParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1)
  settingsParams.setMargins(2, 0, 2, 0)
  btnSettings.setLayoutParams(settingsParams)

  btnSettings.setOnClickListener(function()
    if isRecordingVideo then
      service.speak("Hentikan rekaman video terlebih dahulu.")
      return
    end
    showSettingsMenu()
  end)

  -- 4. Kembali
  local btnClose = Button(service)
  btnClose.setText("Kembali")
  btnClose.setTextSize(13)
  btnClose.setTextColor(Color.WHITE)
  btnClose.setBackgroundColor(Color.parseColor("#DC2626"))
  btnClose.setPadding(0, 12, 0, 12)

  local closeParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1)
  closeParams.setMargins(4, 0, 0, 0)
  btnClose.setLayoutParams(closeParams)

  btnClose.setOnClickListener(function()
    if dialog then
      dialog.dismiss()
    end
  end)

  bottomControlBar.addView(btnMode)
  bottomControlBar.addView(btnSwitchCam)
  bottomControlBar.addView(btnSettings)
  bottomControlBar.addView(btnClose)
  frame.addView(bottomControlBar)

  local builder = AlertDialog.Builder(service)
  builder.setView(frame)
  builder.setCancelable(true)

  dialog = builder.create()

  local win = dialog.getWindow()
  if win then
    win.setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
    win.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
    win.getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_VISIBLE)
  end

  dialog.setOnKeyListener(DialogInterface.OnKeyListener{
    onKey = function(d, keyCode, event)
      if keyCode == KeyEvent.KEYCODE_BACK and event.getAction() == KeyEvent.ACTION_UP then
        d.dismiss()
        return true
      end
      return false
    end
  })

  dialog.setOnDismissListener(DialogInterface.OnDismissListener{
    onDismiss = function()
      releaseCamera()
      if not isSharingAction then
        service.speak("Kamera ditutup.")
      end
    end
  })

  dialog.show()

  if win then
    win.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
  end

  mainHandler.postDelayed(Runnable{
    run = function()
      pcall(function()
        if tvStatus then
          tvStatus.sendAccessibilityEvent(32768)
        end
      end)
    end
  }, 300)
end

launchCamera()
return true