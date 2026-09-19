-- Judul: Kamera selfie by novan
-- Versi: v1.0

require "import"
import "android.hardware.Camera"
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
import "java.lang.System"
import "java.lang.Runnable"
import "java.lang.reflect.Array"

local SCRIPT_TITLE = "Kamera selfie by novan"
local SCRIPT_VERSION = "v1.0"

local mainHandler = Handler(Looper.getMainLooper())
local vibrator = service.getSystemService(Context.VIBRATOR_SERVICE)

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
local flashMode = sp.getString("camera_flash_mode", "off")

local cam = nil
local dialog = nil
local frame = nil
local tvStatus = nil
local currentHolder = nil
local isCapturing = false
local isSettingsOpen = false
local perfectStartTime = nil

local lastSpeakTime = 0
local lastSpeakText = ""
local wasFaceDetected = false
local lastNoFaceAlertTime = 0

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

-- Pengatur ritme ucapan panduan
local function speakGuidance(text, force)
  if isSettingsOpen then return end
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

-- Pelepasan kamera
local function releaseCamera()
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

    if params.getMaxNumDetectedFaces() > 0 then
      cam.setFaceDetectionListener(Camera.FaceDetectionListener{
        onFaceDetection = function(faces, cameraInstance)
          processFaces(faces)
        end
      })
      mainHandler.postDelayed(Runnable{
        run = function()
          pcall(function()
            if cam and not isSettingsOpen then
              cam.startFaceDetection()
              speakGuidance("Arahkan ke wajah Anda.", false)
            end
          end)
        end
      }, 350)
    else
      service.speak("Sensor kamera " .. (cameraFacing == "front" and "depan" or "belakang") .. " tidak mendukung deteksi wajah bawaan.")
    end
  end)
end

-- Proses jepret dan simpan foto ke folder internal Kamera selfie by novan
local function takeSelfiePhoto()
  if not cam or isCapturing or isSettingsOpen then return end
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
                    if cam and not isSettingsOpen then
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
  if isCapturing or isSettingsOpen or not faces then return end

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

-- Dialog Pengaturan Kamera
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
      service.speak("Resolusi diatur ke " .. chosen.width .. " kali " .. chosen.height .. ", " .. mp)
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

  local flashText = "Tidak Aktif"
  if flashMode == "on" then
    flashText = "Aktif"
  elseif flashMode == "auto" then
    flashText = "Otomatis"
  end

  local items = {
    "1. Pilihan Kamera (Aktif: Kamera " .. curCamText .. ")",
    "2. Resolusi Foto (" .. resText .. ")",
    "3. Lampu Kamera / Flash (" .. flashText .. ")",
    "4. Waktu Tahan Jepret (" .. holdSec .. " detik)",
    "5. Suara Jepret Kamera (" .. soundStatus .. ")",
    "6. Getaran (" .. vibStatus .. ")",
    "7. Reset Pengaturan"
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
        showFlashModeDialog()
      elseif which == 3 then
        showHoldTimeDialog()
      elseif which == 4 then
        shutterSoundEnabled = not shutterSoundEnabled
        sp.edit().putBoolean("shutter_sound_enabled", shutterSoundEnabled).apply()
        service.speak("Suara jepret kamera " .. (shutterSoundEnabled and "diaktifkan." or "dinonaktifkan."))
      elseif which == 5 then
        vibrationEnabled = not vibrationEnabled
        sp.edit().putBoolean("vibration_enabled", vibrationEnabled).apply()
        service.speak("Getaran " .. (vibrationEnabled and "diaktifkan." or "dinonaktifkan."))
      elseif which == 6 then
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
        if cam and not isCapturing then
          cam.startFaceDetection()
          service.speak("Kamera aktif kembali.")
        end
      end)
    end
  })
end

-- Tampilan utama kamera
local function launchCamera()
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

  tvStatus = TextView(service)
  tvStatus.setText("Kamera aktif")
  tvStatus.setContentDescription("Kamera aktif")
  tvStatus.setTextSize(18)
  tvStatus.setTextColor(Color.WHITE)
  tvStatus.setBackgroundColor(Color.parseColor("#99000000"))
  tvStatus.setPadding(30, 24, 30, 24)
  tvStatus.setGravity(Gravity.CENTER)
  tvStatus.setFocusable(true)

  local tvParams = FrameLayout.LayoutParams(
    ViewGroup.LayoutParams.MATCH_PARENT,
    ViewGroup.LayoutParams.WRAP_CONTENT,
    Gravity.TOP
  )
  tvStatus.setLayoutParams(tvParams)
  frame.addView(tvStatus)

  -- Bilah tombol bawah
  local bottomControlBar = LinearLayout(service)
  bottomControlBar.setOrientation(LinearLayout.HORIZONTAL)
  bottomControlBar.setBackgroundColor(Color.parseColor("#CC000000"))
  bottomControlBar.setPadding(20, 16, 20, 16)

  local barParams = FrameLayout.LayoutParams(
    ViewGroup.LayoutParams.MATCH_PARENT,
    ViewGroup.LayoutParams.WRAP_CONTENT,
    Gravity.BOTTOM
  )
  bottomControlBar.setLayoutParams(barParams)

  local btnSettings = Button(service)
  btnSettings.setText("Pengaturan")
  btnSettings.setTextSize(17)
  btnSettings.setTextColor(Color.WHITE)
  btnSettings.setBackgroundColor(Color.parseColor("#2563EB"))
  btnSettings.setPadding(0, 16, 0, 16)

  local settingsParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1)
  settingsParams.setMargins(0, 0, 12, 0)
  btnSettings.setLayoutParams(settingsParams)

  btnSettings.setOnClickListener(function()
    showSettingsMenu()
  end)

  local btnClose = Button(service)
  btnClose.setText("Kembali")
  btnClose.setTextSize(17)
  btnClose.setTextColor(Color.WHITE)
  btnClose.setBackgroundColor(Color.parseColor("#DC2626"))
  btnClose.setPadding(0, 16, 0, 16)

  local closeParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1)
  closeParams.setMargins(12, 0, 0, 0)
  btnClose.setLayoutParams(closeParams)

  btnClose.setOnClickListener(function()
    if dialog then
      dialog.dismiss()
    end
  end)

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
