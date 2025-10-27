# 3C-FD-Patcher
While you sleep in the medical room, 3C-FD is patching your game.

<img width="512" height="512" alt="logo" src="https://raw.githubusercontent.com/J0-o/3C-FD-Patcher/refs/heads/main/logo.png" />

Restores fog and reflections which were broken in the Aspyr update. Works with both Steam and GOG versions. Only works on an unmodified swkotor2.exe. WIndows systems only.

Included EXE Patches:
- Fog Fix
- Reflections Fix
- 4GB Patch
- Subtle Color Shift
- Music Volume During Dialogue Fix
- (Experimental) Borderless Window Mode

How to use: 
Run the patcher and choose your swkotor2.exe to patch. It will patch your game exe with the fixes listed above.
It will check if you have an unmodified steam or gog version of the latest (Aspyr) patch, otherwise it wont run.
It will also make a backup of your original swkotor2.exe.

How this was made:
- The fog shading was just covered up when the latest version was released. I was able to send that data to the new Fracture shaders and apply fog coloring. It checks if the fog color is set to black and if not then it applies fog. Modules that don't use fog have a default fog color of black, Duxn and Dantoonie use a grayish color.
- The shader for when both a lightmap and a cubemap is applied, to the same model, had a typo. Cubemap was labeled as a '2D' instead of 'CUBE'. Easy fix.
Luckily the shaders are a plain text string, in the exe, and can be modified with a hex editor. The only issue is that the character length needs to be the same or smaller. The only way to get more data in the shader is to remove extra spaces/linebreaks and to shorten variables to single characters.
- The music was lowered so much during dialogue that it was almost non existent. I was able to find the functions for calling volume control, using ghidra. The call was made only 3 times and from there it was process of elimination. Ultimately disabling a variable change if in dialogue, before the first volume change call, worked.

Bugs:
- This does not work with M478

Special Thanks:
HappyFunTimes101 - ShaderOverride - I could not have done this without this tool. This made sorting out and identifying the shader data much easier. I probably wouldn't have even attempted or known where to look if this didn't exist.
 JCarter426 - For pointing out that the music was broken during dialogue. I hadn't noticed but couldn't stand it after hearing for myself.

## DOWNLOAD
https://github.com/J0-o/3C-FD-Patcher/releases
or
https://deadlystream.com/files/file/2734-fog-fix-more-3c-fd-patcher/
