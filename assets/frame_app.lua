-- we store the data from the host quickly from the data handler interrupt
-- and wait for the main loop to pick it up for processing/drawing
-- app_data contains all camera settings settable from the UI
-- quality, exposure, metering mode, ...
local app_data = { streaming = false, quality = 50, auto_exp_gain_times = 0, metering_mode = "SPOT", exposure = 0, shutter_kp = 0.1, shutter_limit = 6000, gain_kp = 1.0, gain_limit = 248.0}
local quality_values = {10, 25, 50, 100}
local metering_values = {'SPOT', 'CENTER_WEIGHTED', 'AVERAGE'}

-- Frame to phone flags
BATTERY_LEVEL_FLAG = "\x0c"
NON_FINAL_CHUNK_FLAG = "\x07"
FINAL_CHUNK_FLAG = "\x08"

-- Phone to Frame flags
START_STREAM_FLAG = 0x0a
STOP_STREAM_FLAG = 0x0b
CAMERA_SETTINGS_FLAG = 0x0d

-- every time byte data arrives just extract the data payload from the message
-- and save to the local app_data table so the main loop can pick it up and print it
function data_handler(data)
    if string.byte(data, 1) == START_STREAM_FLAG then
        app_data.streaming = true
    elseif string.byte(data, 1) == STOP_STREAM_FLAG then
        app_data.streaming = false
    elseif string.byte(data, 1) == CAMERA_SETTINGS_FLAG then
        -- quality and metering mode are indices into arrays of values (0-based phoneside, 1-based in Lua)
        -- exposure maps from 0..255 to -2.0..+2.0
        app_data.quality = quality_values[string.byte(data, 2) + 1]
        app_data.auto_exp_gain_times = string.byte(data, 3)
        app_data.metering_mode = metering_values[string.byte(data, 4) + 1]
        app_data.exposure = (string.byte(data, 5) - 128) / 64.0
        app_data.shutter_kp = string.byte(data, 6) / 10.0
        app_data.shutter_limit = string.byte(data, 7) << 8 | string.byte(data, 8)
        app_data.gain_kp = string.byte(data, 9) / 10.0
        app_data.gain_limit = string.byte(data, 10)
    end
end

function show_streaming()
    frame.display.text("Streaming", 1, 1)
    frame.display.show()
    frame.sleep(0.04)
end

function clear_display()
    frame.display.text(" ", 1, 1)
    frame.display.show()
    frame.sleep(0.04)
end

function send_batt_if_elapsed(prev, interval)
    local t = frame.time.utc()
    if ((prev == 0) or ((t - prev) > interval)) then
        pcall(frame.bluetooth.send, BATTERY_LEVEL_FLAG .. string.char(math.floor(frame.battery_level())))
        return t
    else
        return prev
    end
end

-- Main app loop
function app_loop()
    local max_payload = frame.bluetooth.max_length() - 4
    local last_batt_update = 0
    local first_photo = true
    local finished_reading = true
    local finished_sending = true
    local image_data_table = {}

    while true do
        -- only stream images while streaming is set
        if (app_data.streaming) then
            if (first_photo) then
                show_streaming()
                first_photo = false
            end
            rc, err = pcall(
                function()
                    if finished_reading and finished_sending then
                        -- take a new photo
                        finished_reading = false
                        finished_sending = false
                        frame.camera.capture { quality_factor = app_data.quality }

                    elseif (not finished_sending) and (image_data_table[1] ~= nil) then
                        -- send all of the data from the previous image
                        local i = 1
                        for k, v in pairs(image_data_table) do
                            pcall(frame.bluetooth.send, NON_FINAL_CHUNK_FLAG .. v)

                            -- need to slow down the bluetooth sends to about 1 per 12.5ms, so every 100ms run the autoexposure algorithm
                            if (i % 8 == 0) then -- roughly once per 100ms
                                frame.camera.auto { metering = app_data.metering_mode, exposure = app_data.exposure, shutter_kp = app_data.shutter_kp, shutter_limit = app_data.shutter_limit, gain_kp = app_data.gain_kp, gain_limit = app_data.gain_limit }
                                frame.sleep(0.0075) -- autoexp algo can take as little as 5ms so top it up here to 12.5
                            else
                                frame.sleep(0.0125) -- can't seem to be any faster than 12.5ms without clobbering previous bluetooth.send()s
                            end

                            i = i + 1
                        end
                        pcall(frame.bluetooth.send, FINAL_CHUNK_FLAG)


                        finished_sending = true
                        for k, v in pairs(image_data_table) do image_data_table[k] = nil end

                    elseif finished_sending and not finished_reading then
                        -- read all the image data from the fpga
                        while true do
                            local data = frame.camera.read(max_payload)
                            if (data == nil) then
                                break
                            end
                            table.insert(image_data_table, data)
                        end

                        finished_reading = true

                    else
                        -- not ready to read, nothing to send
                        finished_sending = true
                    end
                end
            )
            -- Catch the break signal here and clean up the display
            if rc == false then
                -- send the error back on the stdout stream
                print(err)
                clear_display()
                break
            end
        else
            -- TODO might need to clean up if we were part-way through capture/read or sending over bluetooth when app_data.streaming was checked and was false
            first_photo = true
            frame.sleep(0.1)
        end

        -- periodic battery level updates, 30s for a photo streaming app
        last_batt_update = send_batt_if_elapsed(last_batt_update, 30)
    end
end

-- register the handler as a callback for all data sent from the host
frame.bluetooth.receive_callback(data_handler)

-- run the main app loop
app_loop()