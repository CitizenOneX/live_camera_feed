-- we store the data from the host quickly from the data handler interrupt
-- and wait for the main loop to pick it up for processing/drawing
-- app_data contains all camera settings settable from the UI
-- quality, exposure, metering mode, {zoom, ...?}
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

function cameraCaptureAndSend()
	local autoexp_run = 1
	local state = 'EXPOSING'
	local state_time = frame.time.utc()
	local chunkIndex = 0
	if app_data.auto_exp_gain_times == 0 then
			state = 'CAPTURE'
	end

	while true do
		if state == 'EXPOSING' then
            if autoexp_run <= app_data.auto_exp_gain_times then
                    frame.camera.auto { metering = app_data.metering_mode, exposure = app_data.exposure, shutter_kp = app_data.shutter_kp, shutter_limit = app_data.shutter_limit, gain_kp = app_data.gain_kp, gain_limit = app_data.gain_limit }
                    autoexp_run = autoexp_run + 1
                    frame.sleep(0.1)
            else
                    state = 'CAPTURE'
            end
		elseif state == 'CAPTURE' then
				frame.camera.capture { quality_factor = app_data.quality }
				state_time = frame.time.utc()
				state = 'WAIT'
		elseif state == 'WAIT' then
                -- TODO what happens when I start reading sooner than this?
				if frame.time.utc() > state_time + 0.5 then
					state = 'SEND'
				end
		elseif state == 'SEND' then
				local i = frame.camera.read(frame.bluetooth.max_length() - 4)
				if (i == nil) then
						state = 'DONE'
				else
					while true do
							if pcall(frame.bluetooth.send, NON_FINAL_CHUNK_FLAG .. i) then
									break
							end
							frame.sleep(0.01)
					end
					chunkIndex = chunkIndex + 1
				end
		elseif state == 'DONE' then
			while true do
				if pcall(frame.bluetooth.send, FINAL_CHUNK_FLAG .. chunkIndex) then
					break
				end
			end
			break
		end
	end
end

-- every time byte data arrives just extract the data payload from the message
-- and save to the local app_data table so the main loop can pick it up and print it
-- format of [data] (a multi-line text string) is:
-- first digit will be 0x0a/0x0b non-final/final chunk of long text
-- followed by string bytes out to the mtu
function data_handler(data)
    if string.byte(data, 1) == START_STREAM_FLAG then
        -- non-final chunk
        app_data.streaming = true
    elseif string.byte(data, 1) == STOP_STREAM_FLAG then
        -- final chunk
        app_data.streaming = false
    elseif string.byte(data, 1) == CAMERA_SETTINGS_FLAG then
        -- quality and metering mode are indices into arrays of values
        -- exposure maps from 0..255 to -2.0..+2.0
        app_data.quality = quality_values[string.byte(data, 2)]
        app_data.auto_exp_gain_times = string.byte(data, 3)
        app_data.metering_mode = metering_values[string.byte(data, 4)]
        app_data.exposure = (string.byte(data, 5) - 128) / 64.0
        app_data.shutter_kp = string.byte(data, 6) / 10.0
        app_data.shutter_limit = string.byte(data, 7) << 8 | string.byte(data, 8)
        app_data.gain_kp = string.byte(data, 9) / 10.0
        app_data.gain_limit = string.byte(data, 10)
        print(app_data.auto_exp_gain_times)
        print(app_data.exposure)
        print(app_data.shutter_kp)
        print(app_data.shutter_limit)
        print(app_data.gain_kp)
        print(app_data.gain_limit)
    end
end

-- Main app loop
function app_loop()
    local last_batt_update = 0
    local first_photo = true
    while true do
        -- only stream images while streaming is set
        if (app_data.streaming) then
            if (first_photo) then
                frame.display.text("Streaming", 1, 1)
                frame.display.show()
                frame.sleep(0.04)
                first_photo = false
            end
            rc, err = pcall(
                function()
                    cameraCaptureAndSend()
                    frame.sleep(0.1)
                end
            )
            -- Catch the break signal here and clean up the display
            if rc == false then
                -- send the error back on the stdout stream
                print(err)
                frame.display.text(" ", 1, 1)
                frame.display.show()
                frame.sleep(0.04)
                break
            end
        else
            first_photo = true
            frame.sleep(0.1)
        end

        -- periodic battery level updates, 30s for a photo streaming app
        local t = frame.time.utc()
        if (last_batt_update == 0 or (t - last_batt_update) > 30) then
            pcall(frame.bluetooth.send, BATTERY_LEVEL_FLAG .. string.char(math.floor(frame.battery_level())))
            last_batt_update = t
        end
    end
end

-- register the handler as a callback for all data sent from the host
frame.bluetooth.receive_callback(data_handler)

-- run the main app loop
app_loop()