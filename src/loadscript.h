#pragma once

#include <string>

std::string script = R"(printidentity()
game:GetService("TestService"):Message("Debug message"))";

std::string printall = R"(
local debug = game:GetService("TestService")
local players = game:GetService("Players")
local localChar = players.LocalPlayer.Character
for _, v in pairs(localChar:GetDescendants()) do
    debug:Message(v:GetFullName())
end
)";

std::string unc = R"(
loadstring(game:HttpGet("https://github.com/ltseverydayyou/uuuuuuu/blob/main/UNC%20test?raw=true"))()
)";

std::string httptest = R"(local response = game:HttpGet("https://api.myip.com")
game:GetService("TestService"):Message(response))
)";