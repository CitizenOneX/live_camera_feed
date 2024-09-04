local data = require('data.min')
local battery = require('battery.min')

-- Frame to phone flags
NON_FINAL_CHUNK_MSG = 0x07
FINAL_CHUNK_MSG = 0x08

-- Phone to Frame flags
STREAM_MSG = 0x0a
CAMERA_SETTINGS_MSG = 0x0d

-- parse the stream message
function parse_stream(data)
    local msg = {}
    if string.byte(data, 1) == 1 then
        msg.streaming = true
    else
        msg.streaming = false
    end
    return msg
end

local quality_values = { 10, 25, 50, 100 }
local metering_values = { "SPOT", "CENTER_WEIGHTED", "AVERAGE" }

-- parse the camera_settings message
function parse_camera_settings(data)
    local msg = {}
    msg.quality = quality_values[string.byte(data, 1) + 1]
    msg.auto_exp_gain_times = string.byte(data, 2)
    msg.metering_mode = metering_values[string.byte(data, 3) + 1]
    msg.exposure = (string.byte(data, 4) - 128) / 64.0
    msg.shutter_kp = string.byte(data, 5) / 10.0
    msg.shutter_limit = string.byte(data, 6) << 8 | string.byte(data, 7)
    msg.gain_kp = string.byte(data, 8) / 10.0
    msg.gain_limit = string.byte(data, 9)
    return msg
end

-- register the message parsers so they are automatically called when matching data comes in
data.parsers[CAMERA_SETTINGS_MSG] = parse_camera_settings
data.parsers[STREAM_MSG] = parse_stream


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

-- Main app loop
function app_loop()
    local max_payload = frame.bluetooth.max_length() - 4
    local last_batt_update = 0
    local camera_settings = { quality = 50, auto_exp_gain_times = 0, metering_mode = "SPOT", exposure = 0, shutter_kp = 0.1, shutter_limit = 6000, gain_kp = 1.0, gain_limit = 248.0 }
    local streaming = false
    local finished_reading = true
    local finished_sending = true
    local image_data_table = {}

    while true do
		-- process any raw data items, if ready (parse into take_photo, then clear data.app_data_block)
		local items_ready = data.process_raw_items()

        if items_ready > 0 then
            if data.app_data[CAMERA_SETTINGS_MSG] ~= nil then
                camera_settings = data.app_data[CAMERA_SETTINGS_MSG]
                data.app_data[CAMERA_SETTINGS_MSG] = nil
            end
            if data.app_data[STREAM_MSG] ~= nil then
                streaming = data.app_data[STREAM_MSG].streaming
                data.app_data[STREAM_MSG] = nil

                if streaming then
                    show_streaming()
                else
                    clear_display()
                end
            end
        end

        -- only stream images while streaming is set
        if streaming then
            rc, err = pcall(
                function()
                    if finished_reading and finished_sending then
                        -- take a new photo
                        finished_reading = false
                        finished_sending = false
                        frame.camera.capture { quality_factor = camera_settings.quality }

                    elseif (not finished_sending) and (image_data_table[1] ~= nil) then
                        -- send all of the data from the previous image
                        local i = 1
                        for k, v in pairs(image_data_table) do
                            pcall(frame.bluetooth.send, string.char(NON_FINAL_CHUNK_MSG) .. v)

                            -- need to slow down the bluetooth sends to about 1 per 12.5ms, so every 100ms run the autoexposure algorithm
                            if (i % 8 == 0) then -- roughly once per 100ms
                                frame.camera.auto { metering = camera_settings.metering_mode, exposure = camera_settings.exposure, shutter_kp = camera_settings.shutter_kp, shutter_limit = camera_settings.shutter_limit, gain_kp = camera_settings.gain_kp, gain_limit = camera_settings.gain_limit }
                                frame.sleep(0.0075) -- autoexp algo can take as little as 5ms so top it up here to 12.5
                            else
                                frame.sleep(0.0125) -- can't seem to be any faster than 12.5ms without clobbering previous bluetooth.send()s
                            end

                            i = i + 1
                        end
                        pcall(frame.bluetooth.send, string.char(FINAL_CHUNK_MSG))


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
            frame.sleep(0.1)
        end

        -- periodic battery level updates, 60s for a photo streaming app
        last_batt_update = battery.send_batt_if_elapsed(last_batt_update, 60)
    end
end

-- run the main app loop
app_loop()