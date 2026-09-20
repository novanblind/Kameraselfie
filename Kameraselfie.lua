-- Judul: Kamera selfie by novan
-- Versi: v2.0

require "import"
import "android.hardware.Camera"
import "android.hardware.Sensor"
import "android.hardware.SensorEvent"
import "android.hardware.SensorEventListener"
import "android.hardware.SensorManager"
import "android.media.MediaRecorder"
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
import "android.graphics.Color"
import "android.app.AlertDialog"
import "android.content.Context"
import "android.content.DialogInterface"
import "android.content.Intent"
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
local SCRIPT_VERSION = "v2.0"
local UPDATE_URL = "https://raw.githubusercontent.com/novanblind/Kameraselfie/main/Kameraselfie.lua"

local mainHandler = Handler(Looper.getMainLooper())
local vibrator = service.getSystemService(Context.VIBRATOR_SERVICE)
local sensorManager = service.getSystemService(Context.SENSOR_SERVICE)
local accelerometer = nil
if sensorManager then
  pcall(function()
    accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
  end)
end

-- Inisialisasi suara jepret kamera bawaan sistem HP
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
local selectedWidth = sp.getInt("pic_width", 0)
local selectedHeight = sp.getInt("pic_height", 0)
local selectedVideoWidth = sp.getInt("video_width", 0)
local selectedVideoHeight = sp.getInt("video_height", 0)
local flashMode = sp.getString("camera_flash_mode", "off")
local shakeSensitivity = sp.getInt("shake_sensitivity", 22) -- 14: Tinggi, 22: Sedang, 32: Rendah

local cam = nil
local dialog = nil
local frame = nil
local tvStatus = nil
local btnMode = nil
local btnRecordVideo = nil
local currentHolder = nil
local isCapturing = false
local isSettingsOpen = false
local isRecordingVideo = false
local mediaRecorder = nil
local perfectStartTime = nil

local currentMode = "photo" -- "photo" atau "video"

local lastSpeakTime = 0
local lastSpeakText = ""
local wasFaceDetected = false
local lastNoFaceAlertTime = 0

-- Variabel sensor goyangan
local lastSensorX, lastSensorY, lastSensorZ = 0, 0, 0
local lastSensorUpdate = 0
local lastShakeTriggerTime = 0
local isSensorRegistered = false

-- Deklarasi fungsi
local stopVideoRecording
local startVideoRecording

-- Tampilan overlay dialog
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

-- Listener sensor akselerometer untuk mendeteksi goyangan
local sensorListener = SensorEventListener{
  onSensorChanged = function(event)
    if not isRecordingVideo then return end
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

-- Fitur cek pembaruan dengan dialog konfirmasi
local function checkUpdateWithDialog()
  Thread(Runnable{
    run = function()
      pcall(function()
        local info = debug.getinfo(1, "S")
        local scriptPath = info and info.source
        if not scriptPath or scriptPath:sub(1, 1) ~= "@" then return end
        scriptPath = scriptPath:sub(2)

        local curFile = File(scriptPath)
        if not curFile.exists() or not curFile.canWrite() then return end

        local url = URL(UPDATE_URL)
        local conn = url.openConnection()
        conn.setRequestMethod("GET")
        conn.setConnectTimeout(8000)
        conn.setReadTimeout(8000)
        conn.setUseCaches(false)

        if conn.getResponseCode() == 200 then
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

          local newContent = table.concat(sb, "\n")
          if #newContent > 500 then
            local remoteVersion = newContent:match('SCRIPT_VERSION%s*=%s*"([^"]+)"') or newContent:match('%-%-%s*Versi:%s*(v[%d%.]+)')

            if remoteVersion and remoteVersion ~= SCRIPT_VERSION then
              mainHandler.post(Runnable{
                run = function()
                  local builder = AlertDialog.Builder(service)
                    .setTitle("Pembaruan Tersedia")
                    .setMessage("Versi yang sedang digunakan: " .. SCRIPT_VERSION .. "\nVersi baru tersedia: " .. remoteVersion .. "\n\nApakah Anda ingin memperbarui skrip sekarang?")
                    .setPositiveButton("Perbarui", function(dlg)
                      dlg.dismiss()
                      service.speak("Mengunduh pembaruan...")

                      Thread(Runnable{
                        run = function()
                          pcall(function()
                            local fos = FileOutputStream(curFile)
                            fos.write(String(newContent).getBytes("UTF-8"))
                            fos.flush()
                            fos.close()

                            mainHandler.post(Runnable{
                              run = function()
                                local doneBuilder = AlertDialog.Builder(service)
                                  .setTitle("Download Selesai")
                                  .setMessage("Pembaruan ke versi " .. remoteVersion .. " telah selesai diunduh dan dipasang.")
                                  .setPositiveButton("Oke", function(d)
                                    d.dismiss()
                                  end)
                                displayOverlayDialog(doneBuilder)
                                service.speak("Download selesai. Pembaruan berhasil dipasang.")
                              end
                            })
                          end)
                        end
                      }).start()
                    end)
                    .setNegativeButton("Nanti", function(dlg)
                      dlg.dismiss()
                    end)

                  displayOverlayDialog(builder)
                  service.speak("Pembaruan tersedia. Versi baru " .. remoteVersion .. ", versi yang sedang digunakan " .. SCRIPT_VERSION .. ".")
                end
              })
            end
          end
        end
        conn.disconnect()
      end)
    end
  }).start()
end

-- Pengatur ritme ucapan panduan
local function speakGuidance(text, force)
  if isSettingsOpen or isRecordingVideo or currentMode == "video" then return end
  local now = System.currentTimeMillis()

  if not force and text == lastSpeakText and (now - lastSpeakTime < 4000) then
    return
  end
  if not force and (now - lastSpeakTime < 2800) then
    return
  end

  lastSpeakTime = now
  lastSpeakText = text
  mainHandler.post(Runnable{
    run = function()
      pcall(function()
        if force then
          service.speak(0)
        end
        service.speak(text)
      end)
    end
  })
end

local function getCameraId(facingType)
  local targetFacing = (facingType == "back") and Camera.CameraInfo.CAMERA_FACING_BACK or Camera.CameraInfo.CAMERA_FACING_FRONT
  local count = Camera.getNumberOfCameras()
  local info = Camera.CameraInfo()
  for i = 0, count - 1 do
    Camera.getCameraInfo(i, info)
    if info.facing == targetFacing then
      return i
    end
  end
  return 0
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

-- Mengambil daftar resolusi video dari terendah ke tertinggi
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
    -- Diurutkan dari yang paling rendah sampai paling tinggi
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

-- Pelepasan kamera dan perekam video
local function releaseCamera()
  if isRecordingVideo then
    stopVideoRecording()
  end
  unregisterShakeListener()
  if cam then
    pcall(function()
      cam.stopFaceDetection()
      cam.stopPreview()
      cam.setFaceDetectionListener(nil)
      cam.release()
    end)
    cam = nil
  end
end

local processFaces

local function startCameraPreview(holder)
  if not holder then return end
  releaseCamera()

  pcall(function()
    local camId = getCameraId(cameraFacing)
    cam = Camera.open(camId)
    cam.setDisplayOrientation(90)
    cam.setPreviewDisplay(holder)

    local params = cam.getParameters()
    if cameraFacing == "front" then
      params.setRotation(270)
    else
      params.setRotation(90)
    end

    local supportedSizes = getSortedPictureSizes(params)
    local isSizeValid = false
    if selectedWidth > 0 and selectedHeight > 0 then
      for _, sz in ipairs(supportedSizes) do
        if sz.width == selectedWidth and sz.height == selectedHeight then
          isSizeValid = true
          break
        end
      end
    end

    if isSizeValid then
      params.setPictureSize(selectedWidth, selectedHeight)
    elseif #supportedSizes > 0 then
      selectedWidth = supportedSizes[1].width
      selectedHeight = supportedSizes[1].height
      params.setPictureSize(selectedWidth, selectedHeight)
      sp.edit().putInt("pic_width", selectedWidth).putInt("pic_height", selectedHeight).apply()
    end

    applyFlashModeToParams(params)
    cam.setParameters(params)
    cam.startPreview()

    wasFaceDetected = false
    lastNoFaceAlertTime = System.currentTimeMillis() + 2000

    if currentMode == "photo" then
      if params.getMaxNumDetectedFaces() > 0 then
        cam.setFaceDetectionListener(Camera.FaceDetectionListener{
          onFaceDetection = function(faces, cameraInstance)
            processFaces(faces)
          end
        })
        mainHandler.postDelayed(Runnable{
          run = function()
            pcall(function()
              if cam and not isSettingsOpen and currentMode == "photo" then
                cam.startFaceDetection()
                speakGuidance("Arahkan ke wajah Anda.", false)
              end
            end)
          end
        }, 350)
      else
        service.speak("Sensor kamera " .. (cameraFacing == "front" and "depan" or "belakang") .. " tidak mendukung deteksi wajah bawaan.")
      end
    end
  end)
end

-- Penghentian perekaman video (lewat goyangan HP atau tombol)
stopVideoRecording = function()
  if not isRecordingVideo then return end
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

  mainHandler.post(Runnable{
    run = function()
      if btnRecordVideo then
        btnRecordVideo.setText("Mulai Rekam Video")
        btnRecordVideo.setBackgroundColor(Color.parseColor("#16A34A"))
      end
      if tvStatus then
        tvStatus.setText("Video berhasil disimpan")
      end
      service.speak("Rekaman video selesai dan berhasil disimpan.")
    end
  })
end

-- Memulai perekaman video
startVideoRecording = function()
  if isRecordingVideo or not cam or isCapturing or isSettingsOpen then return end

  pcall(function()
    cam.stopFaceDetection()
  end)

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
      mediaRecorder.setVideoSize(selectedVideoWidth, selectedVideoHeight)
    end

    local dir = File("/sdcard/" .. SCRIPT_TITLE)
    if not dir.exists() then dir.mkdirs() end
    local nowStr = os.date("%Y%m%d_%H%M%S")
    local videoFile = File(dir, "Video_" .. cameraFacing .. "_" .. nowStr .. ".mp4")

    mediaRecorder.setOutputFile(videoFile.getAbsolutePath())
    mediaRecorder.setPreviewDisplay(currentHolder.getSurface())

    mediaRecorder.prepare()
    mediaRecorder.start()
    startSuccess = true
  end)

  if startSuccess then
    isRecordingVideo = true
    registerShakeListener()
    triggerVibrate(100)
    if btnRecordVideo then
      btnRecordVideo.setText("Sedang Merekam... (Goyangkan HP untuk Berhenti)")
      btnRecordVideo.setBackgroundColor(Color.parseColor("#DC2626"))
    end
    if tvStatus then
      tvStatus.setText("Merekam video... Goyangkan HP untuk berhenti")
    end
    service.speak("Mulai merekam video. Goyangkan HP untuk berhenti merekam.")
  else
    pcall(function()
      if mediaRecorder then
        mediaRecorder.release()
        mediaRecorder = nil
      end
      if cam then
        cam.lock()
      end
    end)
    service.speak("Gagal memulai perekaman video. Pastikan izin mikrofon dan resolusi video telah sesuai.")
  end
end

-- Proses jepret dan simpan foto
local function takeSelfiePhoto()
  if not cam or isCapturing or isSettingsOpen or currentMode ~= "photo" then return end
  isCapturing = true

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
          end)

          mainHandler.post(Runnable{
            run = function()
              if success then
                triggerVibrate(120)
                service.speak("Foto berhasil disimpan")
              else
                service.speak("Gagal menyimpan berkas foto.")
              end

              mainHandler.postDelayed(Runnable{
                run = function()
                  isCapturing = false
                  perfectStartTime = nil
                  wasFaceDetected = false
                  lastNoFaceAlertTime = System.currentTimeMillis() + 1500
                  pcall(function()
                    if cam and not isSettingsOpen and currentMode == "photo" then
                      cam.startPreview()
                      cam.startFaceDetection()
                      speakGuidance("Arahkan kembali ke wajah.", true)
                    end
                  end)
                end
              }, 3000)
            end
          })
        end
      }
    )
  end)
end

-- Logika deteksi posisi wajah
processFaces = function(faces)
  if isCapturing or isSettingsOpen or currentMode ~= "photo" or not faces then return end

  local count = 0
  local okLen, lenVal = pcall(function()
    return Array.getLength(faces)
  end)

  if okLen and lenVal then
    count = lenVal
  else
    pcall(function() count = #faces end)
  end

  local now = System.currentTimeMillis()

  if count == 0 then
    perfectStartTime = nil
    if wasFaceDetected then
      wasFaceDetected = false
      lastNoFaceAlertTime = now
      speakGuidance("Wajah terlepas", false)
    elseif (now - lastNoFaceAlertTime >= 6000) then
      lastNoFaceAlertTime = now
      speakGuidance("Wajah belum terlihat", false)
    end
    return
  end

  wasFaceDetected = true

  local face = nil
  local okFace, faceVal = pcall(function()
    return Array.get(faces, 0)
  end)

  if okFace and faceVal then
    face = faceVal
  else
    pcall(function() face = faces[0] or faces[1] end)
  end

  if not face or not face.rect then return end

  local r = face.rect
  local cx = (r.left + r.right) / 2
  local cy = (r.top + r.bottom) / 2
  local faceW = r.right - r.left
  local faceH = r.bottom - r.top
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

-- Dialog pemilihan kamera
local function showCameraSelectionDialog()
  local options = {
    "Kamera Depan (Selfie)",
    "Kamera Belakang"
  }
  local selectedIndex = (cameraFacing == "back") and 1 or 0

  local builder = AlertDialog.Builder(service)
    .setTitle("Pilih Kamera")
    .setSingleChoiceItems(options, selectedIndex, function(dlg, which)
      dlg.dismiss()
      if which == 0 then
        cameraFacing = "front"
      else
        cameraFacing = "back"
      end
      sp.edit().putString("camera_facing", cameraFacing).apply()

      if currentHolder then
        startCameraPreview(currentHolder)
      end
      service.speak("Beralih ke " .. (which == 0 and "Kamera Depan." or "Kamera Belakang."))
    end)
    .setNegativeButton("Batal", nil)

  displayOverlayDialog(builder)
end

-- Dialog resolusi foto
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

  local options = {}
  local selectedIndex = 0

  for idx, s in ipairs(sizes) do
    local mp = string.format("%.1f MP", s.pixels / 1000000)
    table.insert(options, s.width .. " x " .. s.height .. " (" .. mp .. ")")
    if s.width == selectedWidth and s.height == selectedHeight then
      selectedIndex = idx - 1
    end
  end

  local builder = AlertDialog.Builder(service)
    .setTitle("Pilih Resolusi Foto")
    .setSingleChoiceItems(options, selectedIndex, function(dlg, which)
      dlg.dismiss()
      local chosen = sizes[which + 1]
      selectedWidth = chosen.width
      selectedHeight = chosen.height
      sp.edit().putInt("pic_width", selectedWidth).putInt("pic_height", selectedHeight).apply()

      pcall(function()
        local p = cam.getParameters()
        p.setPictureSize(selectedWidth, selectedHeight)
        cam.setParameters(p)
      end)

      local mp = string.format("%.1f Megapixel", chosen.pixels / 1000000)
      service.speak("Resolusi foto diatur ke " .. chosen.width .. " kali " .. chosen.height .. ", " .. mp)
    end)
    .setNegativeButton("Batal", nil)

  displayOverlayDialog(builder)
end

-- Dialog resolusi video (terendah ke tertinggi)
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
    table.insert(options, s.width .. " x " .. s.height .. " (" .. mp .. ")")
    if s.width == selectedVideoWidth and s.height == selectedVideoHeight then
      selectedIndex = idx - 1
    end
  end

  local builder = AlertDialog.Builder(service)
    .setTitle("Pilih Resolusi Video (Terendah ke Tertinggi)")
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

-- Dialog sensitivitas goyangan HP
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
      flashMode = "off"
      selectedWidth = 0
      selectedHeight = 0
      selectedVideoWidth = 0
      selectedVideoHeight = 0
      shakeSensitivity = 22
      wasFaceDetected = false
      lastSpeakText = ""
      lastSpeakTime = 0

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

  pcall(function()
    if cam then cam.stopFaceDetection() end
  end)

  local curCamText = (cameraFacing == "front") and "Depan" or "Belakang"
  local vibStatus = vibrationEnabled and "Aktif" or "Mati"
  local soundStatus = shutterSoundEnabled and "Aktif" or "Mati"
  local holdSec = string.format("%.1f", HOLD_DURATION / 1000)
  local resText = (selectedWidth > 0 and selectedHeight > 0) and (selectedWidth .. "x" .. selectedHeight) or "Otomatis Tertinggi"
  local videoResText = (selectedVideoWidth > 0 and selectedVideoHeight > 0) and (selectedVideoWidth .. "x" .. selectedVideoHeight) or "Standar"

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
    "5. Lampu Kamera / Flash (" .. flashText .. ")",
    "6. Waktu Tahan Jepret (" .. holdSec .. " detik)",
    "7. Suara Jepret Kamera (" .. soundStatus .. ")",
    "8. Getaran (" .. vibStatus .. ")",
    "9. Reset Pengaturan"
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
        showFlashModeDialog()
      elseif which == 5 then
        showHoldTimeDialog()
      elseif which == 6 then
        shutterSoundEnabled = not shutterSoundEnabled
        sp.edit().putBoolean("shutter_sound_enabled", shutterSoundEnabled).apply()
        service.speak("Suara jepret kamera " .. (shutterSoundEnabled and "diaktifkan." or "dinonaktifkan."))
      elseif which == 7 then
        vibrationEnabled = not vibrationEnabled
        sp.edit().putBoolean("vibration_enabled", vibrationEnabled).apply()
        service.speak("Getaran " .. (vibrationEnabled and "diaktifkan." or "dinonaktifkan."))
      elseif which == 8 then
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
      pcall(function()
        if cam and not isCapturing and currentMode == "photo" then
          cam.startFaceDetection()
          service.speak("Kamera aktif kembali.")
        end
      end)
    end
  })
end

-- Pengalih mode foto dan video
local function toggleCameraMode()
  if isRecordingVideo then
    service.speak("Hentikan rekaman terlebih dahulu dengan menggoyangkan HP.")
    return
  end

  if currentMode == "photo" then
    currentMode = "video"
    btnMode.setText("Mode: Video")
    btnMode.setBackgroundColor(Color.parseColor("#7C3AED"))
    btnRecordVideo.setVisibility(View.VISIBLE)
    tvStatus.setText("Mode Video aktif. Siap merekam.")
    pcall(function()
      if cam then cam.stopFaceDetection() end
    end)
    service.speak("Beralih ke mode video. Tekan tombol mulai rekam video.")
  else
    currentMode = "photo"
    btnMode.setText("Mode: Foto")
    btnMode.setBackgroundColor(Color.parseColor("#0284C7"))
    btnRecordVideo.setVisibility(View.GONE)
    tvStatus.setText("Mode Foto: Arahkan ke wajah")
    pcall(function()
      if cam and not isSettingsOpen then cam.startFaceDetection() end
    end)
    service.speak("Beralih ke mode foto. Arahkan kamera ke wajah.")
  end
end

-- Tampilan utama kamera
local function launchCamera()
  -- Memeriksa pembaruan skrip
  checkUpdateWithDialog()

  local initialCamName = (cameraFacing == "front") and "depan" or "belakang"
  service.speak("Membuka kamera " .. initialCamName .. "...")

  local surfaceView = SurfaceView(service)
  surfaceView.setLayoutParams(ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
  surfaceView.setZOrderMediaOverlay(true)
  surfaceView.getHolder().setKeepScreenOn(true)

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

  -- Bar Status Atas
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

  -- Tombol Mulai Rekam Video (Hanya tampil di Mode Video)
  btnRecordVideo = Button(service)
  btnRecordVideo.setText("Mulai Rekam Video")
  btnRecordVideo.setTextSize(17)
  btnRecordVideo.setTextColor(Color.WHITE)
  btnRecordVideo.setBackgroundColor(Color.parseColor("#16A34A"))
  btnRecordVideo.setPadding(20, 18, 20, 18)
  btnRecordVideo.setVisibility(View.GONE)

  local recordParams = FrameLayout.LayoutParams(
    ViewGroup.LayoutParams.MATCH_PARENT,
    ViewGroup.LayoutParams.WRAP_CONTENT,
    Gravity.BOTTOM
  )
  recordParams.setMargins(24, 0, 24, 86)
  btnRecordVideo.setLayoutParams(recordParams)

  btnRecordVideo.setOnClickListener(function()
    if not isRecordingVideo then
      startVideoRecording()
    else
      service.speak("Goyangkan HP Anda untuk berhenti merekam.")
    end
  end)
  frame.addView(btnRecordVideo)

  -- Bilah Kontrol Bawah
  local bottomControlBar = LinearLayout(service)
  bottomControlBar.setOrientation(LinearLayout.HORIZONTAL)
  bottomControlBar.setBackgroundColor(Color.parseColor("#CC000000"))
  bottomControlBar.setPadding(16, 12, 16, 12)

  local barParams = FrameLayout.LayoutParams(
    ViewGroup.LayoutParams.MATCH_PARENT,
    ViewGroup.LayoutParams.WRAP_CONTENT,
    Gravity.BOTTOM
  )
  bottomControlBar.setLayoutParams(barParams)

  -- 1. Tombol Mode Foto / Video
  btnMode = Button(service)
  btnMode.setText("Mode: Foto")
  btnMode.setTextSize(15)
  btnMode.setTextColor(Color.WHITE)
  btnMode.setBackgroundColor(Color.parseColor("#0284C7"))
  btnMode.setPadding(0, 14, 0, 14)

  local modeParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1)
  modeParams.setMargins(0, 0, 8, 0)
  btnMode.setLayoutParams(modeParams)

  btnMode.setOnClickListener(function()
    toggleCameraMode()
  end)

  -- 2. Tombol Pengaturan
  local btnSettings = Button(service)
  btnSettings.setText("Pengaturan")
  btnSettings.setTextSize(15)
  btnSettings.setTextColor(Color.WHITE)
  btnSettings.setBackgroundColor(Color.parseColor("#2563EB"))
  btnSettings.setPadding(0, 14, 0, 14)

  local settingsParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1)
  settingsParams.setMargins(4, 0, 8, 0)
  btnSettings.setLayoutParams(settingsParams)

  btnSettings.setOnClickListener(function()
    if isRecordingVideo then
      service.speak("Hentikan rekaman video terlebih dahulu.")
      return
    end
    showSettingsMenu()
  end)

  -- 3. Tombol Kembali
  local btnClose = Button(service)
  btnClose.setText("Kembali")
  btnClose.setTextSize(15)
  btnClose.setTextColor(Color.WHITE)
  btnClose.setBackgroundColor(Color.parseColor("#DC2626"))
  btnClose.setPadding(0, 14, 0, 14)

  local closeParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1)
  closeParams.setMargins(4, 0, 0, 0)
  btnClose.setLayoutParams(closeParams)

  btnClose.setOnClickListener(function()
    if dialog then
      dialog.dismiss()
    end
  end)

  bottomControlBar.addView(btnMode)
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
      service.speak("Kamera ditutup.")
    end
  })

  dialog.show()

  if win then
    win.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
  end

  mainHandler.postDelayed(Runnable{
    run = function()
      pcall(function()
        tvStatus.requestFocus()
        tvStatus.sendAccessibilityEvent(8)
        tvStatus.sendAccessibilityEvent(32768)
        tvStatus.performAccessibilityAction(64, nil)
      end)
    end
  }, 300)
end

launchCamera()
return true
