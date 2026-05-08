Lua Functions List
Lua Functions



The following functions are available in FCEUX, in addition to standard LUA capabilities:





Emu library



emu.poweron()



Executes a power cycle.



emu.softreset()



Executes a (soft) reset.



emu.speedmode(string mode)



Set the emulator to given speed. The mode argument can be one of these:

       - "normal"

       - "nothrottle" (same as turbo on fceux)

       - "turbo"

       - "maximum"



emu.frameadvance()



Advance the emulator by one frame. It's like pressing the frame advance button once.



Most scripts use this function in their main game loop to advance frames. Note that you can also register functions by various methods that run "dead", returning control to the emulator and letting the emulator advance the frame.  For most people, using frame advance in an endless while loop is easier to comprehend so I suggest  starting with that.  This makes more sense when creating bots. Once you move to creating auxillary libraries, try the register() methods.



emu.pause()



Pauses the emulator.



emu.unpause()



Unpauses the emulator.



emu.exec_count(int count, function func)



Calls given function, restricting its working time to given number of lua cycles. Using this method you can ensure that some heavy operation (like Lua bot) won't freeze FCEUX.



emu.exec_time(int time, function func)



Windows-only. Calls given function, restricting its working time to given number of milliseconds (approximate). Using this method you can ensure that some heavy operation (like Lua bot) won't freeze FCEUX.



emu.setrenderplanes(bool sprites, bool background)



Toggles the drawing of the sprites and background planes. Set to false or nil to disable a pane, anything else will draw them.



emu.message(string message)



Displays given message on screen in the standard messages position. Use gui.text() when you need to position text.



int emu.framecount()



Returns the framecount value. The frame counter runs without a movie running so this always returns a value.



int emu.lagcount()



Returns the number of lag frames encountered. Lag frames are frames where the game did not poll for input because it missed the vblank. This happens when it has to compute too much within the frame boundary. This returns the number indicated on the lag counter.



bool emu.lagged()



Returns true if currently in a lagframe, false otherwise.



emu.setlagflag(bool value)



Sets current value of lag flag.

Some games poll input even in lag frames, so standard way of detecting lag (used by FCEUX and other emulators) does not work for those games, and you have to determine lag frames manually.

First, find RAM addresses that help you distinguish between lag and non-lag frames (e.g. an in-game frame counter that only increments in non-lag frames). Then register memory hooks that will change lag flag when needed.



bool emu.emulating()



Returns true if emulation has started, or false otherwise. Certain operations such as using savestates are invalid to attempt before emulation has started. You probably won't need to use this function unless you want to make your script extra-robust to being started too early.



bool emu.paused()



Returns true if emulator is paused, false otherwise.



bool emu.readonly()

Alias: movie.readonly



Returns whether the emulator is in read-only state.  



While this variable only applies to movies, it is stored as a global variable and can be modified even without a movie loaded.  Hence, it is in the emu library rather than the movie library.



emu.setreadonly(bool state)

Alias: movie.setreadonly



Sets the read-only status to read-only if argument is true and read+write if false.

Note: This might result in an error if the medium of the movie file is not writeable (such as in an archive file).



While this variable only applies to movies, it is stored as a global variable and can be modified even without a movie loaded.  Hence, it is in the emu library rather than the movie library.



emu.getdir()



Returns the path of fceux.exe as a string.



emu.loadrom(string filename)



Loads the ROM from the directory relative to the lua script or from the absolute path. Hence, the filename parameter can be absolute or relative path.



If the ROM can't be loaded, loads the most recent one.



emu.registerbefore(function func)



Registers a callback function to run immediately before each frame gets emulated. This runs after the next frame's input is known but before it's used, so this is your only chance to set the next frame's input using the next frame's would-be input. For example, if you want to make a script that filters or modifies ongoing user input, such as making the game think "left" is pressed whenever you press "right", you can do it easily with this.



Note that this is not quite the same as code that's placed before a call to emu.frameadvance. This callback runs a little later than that. Also, you cannot safely assume that this will only be called once per frame. Depending on the emulator's options, every frame may be simulated multiple times and your callback will be called once per simulation. If for some reason you need to use this callback to keep track of a stateful linear progression of things across frames then you may need to key your calculations to the results of emu.framecount.



Like other callback-registering functions provided by FCEUX, there is only one registered callback at a time per registering function per script. If you register two callbacks, the second one will replace the first, and the call to emu.registerbefore will return the old callback. You may register nil instead of a function to clear a previously-registered callback. If a script returns while it still has registered callbacks, FCEUX will keep it alive to call those callbacks when appropriate, until either the script is stopped by the user or all of the callbacks are de-registered.



emu.registerafter(function func)



Registers a callback function to run immediately after each frame gets emulated. It runs at a similar time as (and slightly before) gui.register callbacks, except unlike with gui.register it doesn't also get called again whenever the screen gets redrawn. Similar caveats as those mentioned in emu.registerbefore apply.



emu.registerexit(function func)



Registers a callback function that runs when the script stops. Whether the script stops on its own or the user tells it to stop, or even if the script crashes or the user tries to close the emulator, FCEUX will try to run whatever Lua code you put in here first. So if you want to make sure some code runs that cleans up some external resources or saves your progress to a file or just says some last words, you could put it here. (Of course, a forceful termination of the application or a crash from inside the registered exit function will still prevent the code from running.)



Suppose you write a script that registers an exit function and then enters an infinite loop. If the user clicks "Stop" your script will be forcefully stopped, but then it will start running its exit function. If your exit function enters an infinite loop too, then the user will have to click "Stop" a second time to really stop your script. That would be annoying. So try to avoid doing too much inside the exit function.



Note that restarting a script counts as stopping it and then starting it again, so doing so (either by clicking "Restart" or by editing the script while it is running) will trigger the callback. Note also that returning from a script generally does NOT count as stopping (because your script is still running or waiting to run its callback functions and thus does not stop... see here for more information), even if the exit callback is the only one you have registered. 



bool emu.addgamegenie(string str)



Adds a Game Genie code to the Cheats menu. Returns false and an error message if the code can't be decoded. Returns false if the code couldn't be added. Returns true if the code already existed, or if it was added.



Usage: emu.addgamegenie("NUTANT")



Note that the Cheats Dialog Box won't show the code unless you close and reopen it.



bool emu.delgamegenie(string str)



Removes a Game Genie code from the Cheats menu. Returns false and an error message if the code can't be decoded. Returns false if the code couldn't be deleted. Returns true if the code didn't exist, or if it was deleted.



Usage: emu.delgamegenie("NUTANT")



Note that the Cheats Dialog Box won't show the code unless you close and reopen it.



emu.print(string str)



Puts a message into the Output Console area of the Lua Script control window. Useful for displaying usage instructions to the user when a script gets run.



emu.getscreenpixel(int x, int y, bool getemuscreen)



Returns the separate RGB components of the given screen pixel, and the palette. Can be 0-255 by 0-239, but NTSC only displays 0-255 x 8-231 of it. If getemuscreen is false, this gets background colors from either the screen pixel or the LUA pixels set, but LUA data may not match the information used to put the data to the screen. If getemuscreen is true, this gets background colors from anything behind an LUA screen element.



Usage is local r,g,b,palette = emu.getscreenpixel(5, 5, false) to retrieve the current red/green/blue colors and palette value of the pixel at 5x5.



Palette value can be 0-63, or 254 if there was an error.



You can avoid getting LUA data by putting the data into a function, and feeding the function name to emu.registerbefore.



emu.getscreenpixel(int x, int y, bool getemuscreen)



Returns the separate RGB components of the given screen pixel, and the 



emu.exit()



Closes FCEUX. Useful for run-and-close scripts like automatic screenshots taking.





FCEU library



The FCEU library is the same as the emu library. It is left in for backwards compatibility. However, the emu library is preferred.





ROM Library



rom.getfilename()



Get the base filename of the ROM loaded.



rom.gethash(string type)



Get a hash of the ROM loaded, for verification. If type is "md5", returns a hex string of the MD5 hash. If type is "base64", returns a base64 string of the MD5 hash, just like the movie romChecksum value.



rom.readbyte(int address)

rom.readbyteunsigned(int address)



Get an unsigned byte from the actual ROM file at the given address.  



This includes the header! It's the same as opening the file in a hex-editor.



rom.readbytesigned(int address)



Get a signed byte from the actual ROM file at the given address. Returns a byte that is signed.



This includes the header! It's the same as opening the file in a hex-editor.



rom.writebyte()



Write the value to the ROM at the given address. The value is modded with 256 before writing (so writing 257 will actually write 1). Negative values allowed.



Editing the header is not available.



Memory Library



memory.readbyte(int address)

memory.readbyteunsigned(int address)



Get an unsigned byte from the RAM at the given address. Returns a byte regardless of emulator. The byte will always be positive.



memory.readbyterange(int address, int length)



Get a length bytes starting at the given address and return it as a string. Convert to table to access the individual bytes.



memory.readbytesigned(int address)



Get a signed byte from the RAM at the given address. Returns a byte regardless of emulator. The most significant bit will serve as the sign.



memory.readword(int addressLow, [int addressHigh])

memory.readwordunsigned(int addressLow, [int addressHigh])



Get an unsigned word from the RAM at the given address. Returns a 16-bit value regardless of emulator. The value will always be positive.

If you only provide a single parameter (addressLow), the function treats it as address of little-endian word. if you provide two parameters, the function reads the low byte from addressLow and the high byte from addressHigh, so you can use it in games which like to store their variables in separate form (a lot of NES games do).



memory.readwordsigned(int addressLow, [int addressHigh])



The same as above, except the returned value is signed, i.e. its most significant bit will serve as the sign.



memory.writebyte(int address, int value)



Write the value to the RAM at the given address. The value is modded with 256 before writing (so writing 257 will actually write 1). Negative values allowed.



int memory.getregister(cpuregistername)



Returns the current value of the given hardware register.

For example, memory.getregister("pc") will return the main CPU's current Program Counter.



Valid registers are: "a", "x", "y", "s", "p", and "pc".



memory.setregister(string cpuregistername, int value)



Sets the current value of the given hardware register.

For example, memory.setregister("pc",0x200) will change the main CPU's current Program Counter to 0x200.



Valid registers are: "a", "x", "y", "s", "p", and "pc".



You had better know exactly what you're doing or you're probably just going to crash the game if you try to use this function. That applies to the other memory.write functions as well, but to a lesser extent. 



memory.register(int address, [int size,] function func)

memory.registerread(int address, [int size,] function func)

memory.registerwrite(int address, [int size,] function func)



Registers a function to be called immediately whenever the given memory address range is read from/written to.



address is the address in CPU address space (0x0000 - 0xFFFF).



size is the number of bytes to "watch". For example, if size is 100 and address is 0x0200, then you will register the function across all 100 bytes from 0x0200 to 0x0263. A write to any of those bytes will trigger the function. Having callbacks on a large range of memory addresses can be expensive, so try to use the smallest range that's necessary for whatever it is you're trying to do. If you don't specify any size then it defaults to 1.



The callback function will receive three arguments (address, size, value) indicating what write operation triggered the callback. If you don't care about that extra information then you can ignore it and define your callback function to not take any arguments. Since 6502 writes are always single byte, the "size" argument will always be 1.



You may use a memory.write function from inside the callback to change the value that just got written. However, keep in mind that doing so will trigger your callback again, so you must have a "base case" such as checking to make sure that the value is not already what you want it to be before writing it. Another, more drastic option is to de-register the current callback before performing the write.



If func is nil that means to de-register any memory write callbacks that the current script has already registered on the given range of bytes.



memory.registerexec(int address, [int size,] function func)

memory.registerrun(int address, [int size,] function func)

memory.registerexecute(int address, [int size,] function func)



Registers a function to be called immediately whenever the emulated system runs code located in the given memory address range.



Since "address" is the address in CPU address space (0x0000 - 0xFFFF), this doesn't take ROM banking into account, so the callback will be called for any bank, and in some cases you'll have to check current bank in your callback function.



The information about memory.register applies to this function as well. The callback will receive the same three arguments, though the "value" argument will always be 0.



Example of custom breakpoint:



function CounterBreak()

ObjCtr = memory.getregister("y")

if ObjCtr > 0x16 then

gui.text(1, 9, string.format("%02X",ObjCtr))

emu.pause() -- or debugger.hitbreakpoint()

end

end

memory.registerexecute(0x863C, CounterBreak);





PPU Library



ppu.readbyte(int address)



Get an unsigned byte from the PPU at the given address. Returns a byte regardless of emulator. The byte will always be positive.



ppu.readbyterange(int address, int length)



Get a length bytes starting at the given address and return it as a string. Convert to table to access the individual bytes.





Debugger Library



debugger.hitbreakpoint()



Simulates a breakpoint hit, pauses emulation and brings up the Debugger window. Use this function in your handlers of custom breakpoints.



int debugger.getcyclescount()



Returns an integer value representing the number of CPU cycles elapsed since the poweron or since the last reset of the cycles counter.



int debugger.getinstructionscount()



Returns an integer value representing the number of CPU instructions executed since the poweron or since the last reset of the instructions counter.



debugger.resetcyclescount()



Resets the cycles counter.



debugger.resetinstructionscount()



Resets the instructions counter.



int debugger.getsymboloffset(string name [, int bank])



Gets the offset (usually the CPU address) of a debug symbol. Returns -1 if the symbol is not found.





Joypad Library



table joypad.get(int player)

table joypad.read(int player)



Returns a table of every game button, where each entry is true if that button is currently held (as of the last time the emulation checked), or false if it is not held. This takes keyboard inputs, not Lua. The table keys look like this (case sensitive):



up, down, left, right, A, B, start, select



Where a Lua truthvalue true means that the button is set, false means the button is unset. Note that only "false" and "nil" are considered a false value by Lua.  Anything else is true, even the number 0.



joypad.read left in for backwards compatibility with older versions of FCEU/FCEUX.



table joypad.getimmediate(int player)

table joypad.readimmediate(int player)



Returns a table of every game button, where each entry is true if that button is held at the moment of calling the function, or false if it is not held. This function polls keyboard input immediately, allowing Lua to interact with user even when emulator is paused.



As of FCEUX 2.2.0, the function only works in Windows. In Linux this function will return nil.



table joypad.getdown(int player)

table joypad.readdown(int player)



Returns a table of only the game buttons that are currently held. Each entry is true if that button is currently held (as of the last time the emulation checked), or nil if it is not held.



table joypad.getup(int player)

table joypad.readup(int player)



Returns a table of only the game buttons that are not currently held. Each entry is nil if that button is currently held (as of the last time the emulation checked), or false if it is not held.



joypad.set(int player, table input)

joypad.write(int player, table input)



Set the inputs for the given player. Table keys look like this (case sensitive):



up, down, left, right, A, B, start, select



There are 4 possible values: true, false, nil, and "invert".

true    - Forces the button on

false   - Forces the button off

nil     - User's button press goes through unchanged

"invert"- Reverses the user's button press



Any string works in place of "invert".  It is suggested as a convention to use "invert" for readability, but strings like "inv", "Weird switchy mechanism", "", or "true or false" works as well as "invert".



nil and "invert" exists so the script can control individual buttons of the controller without entirely blocking the user from having any control. Perhaps there is a process which can be automated by the script, like an optimal firing pattern, but the user still needs some manual control, such as moving the character around.



joypad.write left in for backwards compatibility with older versions of FCEU/FCEUX.





Zapper Library



table zapper.read()



Returns the zapper data

When no movie is loaded this input is the same as the internal mouse input (which is used to generate zapper input, as well as the arkanoid paddle).



When a movie is playing, it returns the zapper data in the movie code.



The return table consists of 3 values: x, y, and fire.  x and y are the x,y coordinates of the zapper target in terms of pixels.  fire represents the zapper firing.  0 = not firing, 1 = firing



zapper.set(table input)



Sets the zapper input state.



Taple entries (nil or -1 to leave unaffected):

x    - Forces the X position

y    - Forces the Y position

fire - Forces trigger (true/1 on, false/0 off)





Note: The zapper is always controller 2 on the NES so there is no player argument to these functions.





Input Library



table input.get()

table input.read()



Reads input from keyboard and mouse. Returns pressed keys and the position of mouse in pixels on game screen.  The function returns a table with at least two properties; table.xmouse and table.ymouse.  Additionally any of these keys will be set to true if they were held at the time of executing this function:

leftclick, rightclick, middleclick, capslock, numlock, scrolllock, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z, F1, F2, F3, F4, F5, F6,  F7, F8, F9, F10, F11, F12, F13, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F24, backspace, tab, enter, shift, control, alt, pause, escape, space, pageup, pagedown, end, home, left, up, right, down, numpad0, numpad1, numpad2, numpad3, numpad4, numpad5, numpad6, numpad7, numpad8, numpad9, numpad*, insert, delete, numpad+, numpad-, numpad., numpad/, semicolon, plus, minus, comma, period, slash, backslash, tilde, quote, leftbracket, rightbracket.



string input.popup

Alias: gui.popup



Requests input from the user using a multiple-option message box. See gui.popup for complete usage and returns.





Savestate Library



object savestate.object(int slot = nil)



Create a new savestate object. Optionally you can save the current state to one of the predefined slots(1-10) using the range 1-9 for slots 1-9, and 10 for 0, QWERTY style. Using no number will create an "anonymous" savestate.

Note that this does not actually save the current state! You need to create this value and pass it on to the load and save functions in order to save it.



Anonymous savestates are temporary, memory only states. You can make them persistent by calling memory.persistent(state). Persistent anonymous states are deleted from disk once the script exits.



object savestate.create(int slot = nil)



savestate.create is identical to savestate.object, except for the numbering for predefined slots(1-10, 1 refers to slot 0, 2-10 refer to 1-9). It's being left in for compatibility with older scripts, and potentially for platforms with different internal predefined slot numbering.



savestate.save(object savestate)



Save the current state object to the given savestate. The argument is the result of savestate.create(). You can load this state back up by calling savestate.load(savestate) on the same object.



savestate.load(object savestate)



Load the the given state. The argument is the result of savestate.create() and has been passed to savestate.save() at least once.



If this savestate is not persistent and not one of the predefined states, the state will be deleted after loading.



savestate.persist(object savestate)



Set the given savestate to be persistent. It will not be deleted when you load this state but at the exit of this script instead, unless it's one of the predefined states.  If it is one of the predefined savestates it will be saved as a file on disk.



savestate.registersave(function func)



Registers a callback function that runs whenever the user saves a state. This won't actually be called when the script itself makes a savestate, so none of those endless loops due to a misplaced savestate.save.



As with other callback-registering functions provided by FCEUX, there is only one registered callback at a time per registering function per script. Upon registering a second callback, the first is kicked out to make room for the second. In this case, it will return the first function instead of nil, letting you know what was kicked out. Registering nil will clear the previously-registered callback.



savestate.registerload(function func)



Registers a callback function that runs whenever the user loads a previously saved state. It's not called when the script itself loads a previous state, so don't worry about your script interrupting itself just because it's loading something.



The state's data is loaded before this function runs, so you can read the RAM immediately after the user loads a state, or check the new framecount. Particularly useful if you want to update lua's display right away instead of showing junk from before the loadstate.



savestate.loadscriptdata(int location)



Accuracy not yet confirmed.



Intended Function, according to snes9x LUA documentation:

Returns the data associated with the given savestate (data that was earlier returned by a registered save callback) without actually loading the rest of that savestate or calling any callbacks. location should be a save slot number.





Movie Library



bool movie.play(string filename, [bool read_only, [int pauseframe]])

bool movie.playback(...)

bool movie.load(...)



Loads and plays a movie from the directory relative to the Lua script or from the absolute path. If read_only is true, the movie will be loaded in read-only mode. The default is read+write.



A pauseframe can be specified, which controls which frame will auto-pause the movie. By default, this is off. A true value is returned if the movie loaded correctly.



bool movie.record(string filename, [int save_type, [string author]])

bool movie.save(...)



Starts recording a movie, using the filename, relative to the Lua script.



An optional save_type can be specified. If set to 0 (default), it will record from a power on state, and automatically do so. This is the recommended setting for creating movies. This can also be set to 1 for savestate or 2 for saveram movies.



A third parameter specifies an author string. If included, it will be recorded into the movie file.



bool movie.active()



Returns true if a movie is currently loaded and false otherwise.  (This should be used to guard against Lua errors when attempting to retrieve movie information).



int movie.framecount()



Returns the current frame count. (Has the same affect as emu.framecount)



string movie.mode()



Returns the current state of movie playback. Returns one of the following:



- "record"

- "playback"

- "finished"

- "taseditor"

- nil



movie.rerecordcounting(bool counting)



Turn the rerecord counter on or off. Allows you to do some brute forcing without inflating the rerecord count.



movie.stop()

movie.close()



Stops movie playback. If no movie is loaded, it throws a Lua error.



int movie.length()



Returns the total number of frames of the current movie. Throws a Lua error if no movie is loaded.



string movie.name()

string movie.getname()



Returns the filename of the current movie with path. Throws a Lua error if no movie is loaded.



movie.getfilename()



Returns the filename of the current movie with no path. Throws a Lua error if no movie is loaded.



movie.rerecordcount()



Returns the rerecord count of the current movie. Throws a Lua error if no movie is loaded.



movie.replay()

movie.playbeginning()



Performs the Play from Beginning function. Movie mode is switched to read-only and the movie loaded will begin playback from frame 1.



If no movie is loaded, no error is thrown and no message appears on screen.



bool movie.readonly()

bool movie.getreadonly()

Alias: emu.getreadonly



FCEUX keeps the read-only status even without a movie loaded.



Returns whether the emulator is in read-only state.  



While this variable only applies to movies, it is stored as a global variable and can be modified even without a movie loaded.  Hence, it is in the emu library rather than the movie library.



movie.setreadonly(bool state)

Alias: emu.setreadonly



FCEUX keeps the read-only status even without a movie loaded.



Sets the read-only status to read-only if argument is true and read+write if false.

Note: This might result in an error if the medium of the movie file is  not writeable (such as in an archive file).



While this variable only applies to movies, it is stored as a global variable and can be modified even without a movie loaded.  Hence, it is in the emu library rather than the movie library.



bool movie.recording()



Returns true if there is a movie loaded and in record mode.



bool movie.playing()



Returns true if there is a movie loaded and in play mode.



bool movie.ispoweron()



Returns true if the movie recording or loaded started from 'Start'.

Returns false if the movie uses a save state.

Opposite of movie.isfromsavestate()



bool movie.isfromsavestate()



Returns true if the movie recording or loaded started from 'Now'.

Returns false if the movie was recorded from a reset.

Opposite of movie.ispoweron()



string movie.name()



If a movie is loaded it returns the name of the movie, else it throws an error.



bool movie.readonly()



Returns the state of read-only. True if in playback mode, false if in record mode.





GUI Library



gui.pixel(int x, int y, type color)

gui.drawpixel(int x, int y, type color)

gui.setpixel(int x, int y, type color)

gui.writepixel(int x, int y, type color)



Draw one pixel of a given color at the given position on the screen. See drawing notes and color notes at the bottom of the page.  



gui.getpixel(int x, int y)



Returns the separate RGBA components of the given pixel set by gui.pixel. This only gets LUA pixels set, not background colors.



Usage is local r,g,b,a = gui.getpixel(5, 5) to retrieve the current red/green/blue/alpha values of the LUA pixel at 5x5.



See emu.getscreenpixel() for an emulator screen variant.



gui.line(int x1, int y1, int x2, int y2 [, color [, skipfirst]])

gui.drawline(int x1, int y1, int x2, int y2 [, color [, skipfirst]])



Draws a line between the two points. The x1,y1 coordinate specifies one end of the line segment, and the x2,y2 coordinate specifies the other end. If skipfirst is true then this function will not draw anything at the pixel x1,y1, otherwise it will. skipfirst is optional and defaults to false. The default color for the line is solid white, but you may optionally override that using a color of your choice. See also drawing notes and color notes at the bottom of the page.



gui.box(int x1, int y1, int x2, int y2 [, fillcolor [, outlinecolor]]))

gui.drawbox(int x1, int y1, int x2, int y2 [, fillcolor [, outlinecolor]]))

gui.rect(int x1, int y1, int x2, int y2 [, fillcolor [, outlinecolor]]))

gui.drawrect(int x1, int y1, int x2, int y2 [, fillcolor [, outlinecolor]]))



Draws a rectangle between the given coordinates of the emulator screen for one frame. The x1,y1 coordinate specifies any corner of the rectangle (preferably the top-left corner), and the x2,y2 coordinate specifies the opposite corner.



The default color for the box is transparent white with a solid white outline, but you may optionally override those using colors of your choice. Also see drawing notes and color notes.



gui.text(int x, int y, string str [, textcolor [, backcolor]])

gui.drawtext(int x, int y, string str [, textcolor [, backcolor]])



Draws a given string at the given position. textcolor and backcolor are optional. See 'on colors' at the end of this page for information. Using nil as the input or not including an optional field will make it use the default.



gui.parsecolor(color)



Returns the separate RGBA components of the given color.

For example, you can say local r,g,b,a = gui.parsecolor('orange') to retrieve the red/green/blue values of the preset color orange. (You could also omit the a in cases like this.) This uses the same conversion method that FCEUX uses internally to support the different representations of colors that the GUI library uses. Overriding this function will not change how FCEUX interprets color values, however.



gui.savescreenshot()

Makes a screenshot of the FCEUX emulated screen, and saves it to the appropriate folder. Performs identically to pressing the Screenshot hotkey.



gui.savescreenshotas(string name)

Makes a screenshot of the FCEUX emulated screen, and saves it to the appropriate folder. However, this one receives a file name for the screenshot.

 

string gui.gdscreenshot(bool getemuscreen)



Takes a screen shot of the image and returns it in the form of a string which can be imported by the gd library using the gd.createFromGdStr() function.



This function is provided so as to allow FCEUX to not carry a copy of the gd library itself. If you want raw RGB32 access, skip the first 11 bytes (header) and then read pixels as Alpha (always 0), Red, Green, Blue, left to right then top to bottom, range is 0-255 for all colors.



If getemuscreen is false, this gets background colors from either the screen pixel or the Lua pixels set, but Lua data may not match the information used to put the data to the screen. If getemuscreen is true, this gets background colors from anything behind a Lua screen element.



Warning: Storing screen shots in memory is not recommended. Memory usage will blow up pretty quick. One screen shot string eats around 230 KB of RAM.



gui.gdoverlay([int dx=0, int dy=0,] string str [, sx=0, sy=0, sw, sh] [, float alphamul=1.0])

gui.image([int dx=0, int dy=0,] string str [, sx=0, sy=0, sw, sh] [, float alphamul=1.0])

gui.drawimage([int dx=0, int dy=0,] string str [, sx=0, sy=0, sw, sh] [, float alphamul=1.0])



Draws an image on the screen. gdimage must be in truecolor gd string format.



Transparency is fully supported. Also, if alphamul is specified then it will modulate the transparency of the image even if it's originally fully opaque. (alphamul=1.0 is normal, alphamul=0.5 is doubly transparent, alphamul=3.0 is triply opaque, etc.)



dx,dy determines the top-left corner of where the image should draw. If they are omitted, the image will draw starting at the top-left corner of the screen.



gui.gdoverlay is an actual drawing function (like gui.box and friends) and thus must be called every frame, preferably inside a gui.register'd function, if you want it to appear as a persistent image onscreen.



Here is an example that loads a PNG from file, converts it to gd string format, and draws it once on the screen:

local gdstr = gd.createFromPng("myimage.png"):gdStr()

gui.gdoverlay(gdstr) 



gui.opacity(int alpha)



Scales the transparency of subsequent draw calls. An alpha of 0.0 means completely transparent, and an alpha of 1.0 means completely unchanged (opaque). Non-integer values are supported and meaningful, as are values greater than 1.0. It is not necessary to use this function (or the less-recommended gui.transparency) to perform drawing with transparency, because you can provide an alpha value in the color argument of each draw call. However, it can sometimes be convenient to be able to globally modify the drawing transparency. 



gui.transparency(int trans)



Scales the transparency of subsequent draw calls. Exactly the same as gui.opacity, except the range is different: A trans of 4.0 means completely transparent, and a trans of 0.0 means completely unchanged (opaque). 



function gui.register(function func)



Register a function to be called between a frame being prepared for displaying on your screen and it actually happening. Used when that 1 frame delay for rendering is not acceptable.



string gui.popup(string message [, string type = "ok" [, string icon = "message"]])

string input.popup(string message [, string type = "yesno" [, string icon = "question"]])



Brings up a modal popup dialog box (everything stops until the user dismisses it). The box displays the message tostring(msg). This function returns the name of the button the user clicked on (as a string).



type determines which buttons are on the dialog box, and it can be one of the following: 'ok', 'yesno', 'yesnocancel', 'okcancel', 'abortretryignore'.

type defaults to 'ok' for gui.popup, or to 'yesno' for input.popup.



icon indicates the purpose of the dialog box (or more specifically it dictates which title and icon is displayed in the box), and it can be one of the following: 'message', 'question', 'warning', 'error'.

icon defaults to 'message' for gui.popup, or to 'question' for input.popup.



Try to avoid using this function much if at all, because modal dialog boxes can be irritating. 



Linux users might want to install xmessage to perform the work. Otherwise the dialog will appear on the shell and that's less noticeable.





Sound Library



table sound.get()



Returns current state of PSG channels in big array.



table:

{

  rp2a03:

  {

    square1:

    {

      volume, -- 0.0-1.0

      frequency, -- in hertz

      midikey, -- 0-127

      duty, -- 0:12.5% 1:25% 2:50% 3:75%

      regs: -- raw register values

      {

        frequency -- raw freq register value

      }

    },

    square2:

    {

      volume, -- 0.0-1.0

      frequency, -- in hertz

      midikey, -- 0-127

      duty, -- 0:12.5% 1:25% 2:50% 3:75%

      regs: -- raw register values

      {

        frequency -- raw freq register value

      }

    },

    triangle:

    {

      volume, -- 0.0-1.0

      frequency, -- in hertz (correct?)

      midikey, -- 0-127 (correct?)

      regs: -- raw register values

      {

        frequency -- raw freq register value

      }

    },

    noise:

    {

      volume, -- 0.0-1.0

       short, -- true or false

      frequency, -- in hertz (correct?)

      midikey, -- 0-127 (correct?)

      regs: -- raw register values

      {

        frequency -- raw freq register value

      }

    },

    dpcm:

    {

      volume, -- 0.0-1.0

      frequency, -- in hertz (correct?)

      midikey, -- 0-127 (correct?)

      dmcaddress, -- start position of the sample

      dmcsize, -- size of the sample, in bytes

      dmcloop, -- true:looped sample, false:oneshot

      dmcseed, -- InitialRawDALatch

      regs: -- raw register values

      {

        frequency -- raw freq register value

      }

    }

  }

}





TAS Editor Library



taseditor.registerauto(function func)

taseditor.registermanual(function func)

bool taseditor.engaged()

bool taseditor.markedframe(int frame)

int taseditor.getmarker(int frame)

int taseditor.setmarker(int frame)

taseditor.clearmarker(int frame)

string taseditor.getnote(int index)

taseditor.setnote(int index, string newtext)

int taseditor.getcurrentbranch()

string taseditor.getrecordermode()

int taseditor.getsuperimpose()

int taseditor.getlostplayback()

int taseditor.getplaybacktarget()

taseditor.setplayback(int frame)

taseditor.stopseeking()

taseditor.getselection()

taseditor.setselection()

int taseditor.getinput(int frame, int joypad)

taseditor.submitinputchange(int frame, int joypad, int input)

taseditor.submitinsertframes(int frame, int number)

taseditor.submitdeleteframes(int frame, int number)

int taseditor.applyinputchanges([string name])

taseditor.clearinputchanges()



For full description of these functions refer to TAS Editor Manual.





Bitwise Operations



The following bit functions were added to FCEUX internally to compensate for Lua's lack of them. But it also supports all operations from LuaBitOp module, since it is also embedded in FCEUX.



int AND(int n1, int n2, ..., int nn)



Binary logical AND of all the given integers.



int OR(int n1, int n2, ..., int nn)



Binary logical OR of all the given integers.



int XOR(int n1, int n2, ..., int nn)



Binary logical XOR of all the given integers. 



int BIT(int n1, int n2, ..., int nn)



Returns an integer with the given bits turned on. Parameters should be smaller than 31.



Appendix



On drawing



A general warning about drawing is that it is always one frame behind unless you use gui.register. This is because you tell the emulator to paint something but it will actually paint it when generating the image for the next frame. So you see your painting, except it will be on the image of the next frame. You can prevent this with gui.register because it gives you a quick chance to paint before blitting.



Dimensions & color depths you can paint in:

--320x239, 8bit color (confirm?)

256x224, 8bit color (confirm?)



On colors



Colors can be of a few types.

Int: use the a formula to compose the color as a number (depends on color depth)

String: Can either be a HTML colors, simple colors, or internal palette colors.

HTML string: "#rrggbb" ("#228844") or #rrggbbaa if alpha is supported.

Simple colors: "clear", "red", "green", "blue", "white", "black", "gray", "grey", "orange", "yellow", "green", "teal", "cyan", "purple", "magenta".

Array: Example: {255,112,48,96} means {red=255, green=112, blue=48, alpha=96} 

Table: Example: {r=255,g=112,b=48,a=96} means {red=255, green=112, blue=48, alpha=96} 

Palette: Example: "P00" for Palette 00. "P3F" for palette 3F. P40-P7F are for LUA.



For transparancy use "clear".