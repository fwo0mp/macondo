#!/usr/bin/env lua

-- Dataset generation script for Macondo
-- Generates a single game state with top 100 moves
-- Usage: script scripts/lua/generate_dataset.lua <min_tiles> <max_tiles>

local macondo = require("macondo")
local json = require("json")

-- Parse command line arguments (args is a single string, not an array)
if not args then
    print("Usage: script scripts/lua/generate_dataset.lua <min_tiles> <max_tiles>")
    print("Example: script scripts/lua/generate_dataset.lua 20 50")
    print("Generates a single game with 20-50 tiles remaining")
    print("")
    print("This script works by:")
    print("1. Starting a new game and simulating AI turns")
    print("2. Capturing position when tiles remaining is in target range")
    print("3. Generating top 100 moves for the position")
    print("4. Outputting the result to console as JSON")
    return
end

local str_args = {}
for arg in args[1]:gmatch("[^%s]+") do
    table.insert(str_args, arg)
end

if #str_args < 2 then
    print("Error: At least 2 arguments are required")
    return
end

local min_tiles = tonumber(str_args[1])
local max_tiles = tonumber(str_args[2])

if not min_tiles or not max_tiles then
    print("Error: Both min_tiles and max_tiles must be numbers")
    print("Received args: '" .. (args or "nil") .. "'")
    return
end

if min_tiles < 0 or max_tiles < 0 or min_tiles > max_tiles then
    print("Error: min_tiles and max_tiles must be non-negative and min_tiles <= max_tiles")
    return
end

local fast = false
if #str_args > 2 then
    if str_args[3] == "fast" then
        fast = true
    else
        print("Error: Invalid argument: " .. str_args[3])
        return
    end
end


-- Helper function to get tiles remaining from game state
function get_tiles_remaining()
    local game_state = macondo.gamestate()
    local unseenStr = game_state:match("(%d+) in the bag")
    return tonumber(unseenStr)
end

-- Helper function to extract moves from gen output
function get_generated_moves()
    local moves = macondo.gen("100 simple")
    
    local res = {}
    for move in moves:gmatch("[^\n]+") do

        -- Strip leading whitespace from move
        move = move:match("^%s*(.-)$")

        -- strip surrounding parens, e.g. exchanges are expressed as (exch ABC)
        move = move:match("^%(?(.-)%)?$")

        -- "pass" is output in upper case but needs to be input in lower case
        move = move:gsub("^Pass$", "pass")

        table.insert(res, move)
    end

    return res
end

-- Function to simulate a game until reaching target tiles remaining
function simulate_to_target_stage(target_min_tiles, target_max_tiles, fast)
    local max_attempts = 10
    local attempt = 0
    
    while attempt < max_attempts do
        attempt = attempt + 1
        
        -- Start a new game
        macondo.new()
        
        -- Play AI turns until we reach the target stage
        while true do
            local tiles_remaining = get_tiles_remaining()
            
            -- Check if we've reached the target stage
            if tiles_remaining >= target_min_tiles and tiles_remaining <= target_max_tiles then
                -- We're in the target range, capture this position
                -- XXX potentially play more turns to get deeper into the stage; otherwise we'll
                -- end up with counts clustering in the earliest part of each range
                local cgp = macondo.cgp()
                return tiles_remaining, cgp
            end
            
            -- Check if we've gone past our target (too few tiles)
            if tiles_remaining < target_min_tiles then
                break -- This game won't work for our target
            end
            
            -- Play an AI move to advance the game
            if fast then
                macondo.commit_hasty()
            else
                macondo.commit_ai()
            end
        end
    end
    
    return nil, nil -- Failed to generate valid position
end

-- Generate single game
local tiles_remaining, cgp = simulate_to_target_stage(min_tiles, max_tiles, fast)

if not cgp then
    print("Failed to generate game position with " .. min_tiles .. "-" .. max_tiles .. " tiles remaining")
    return
end

-- Generate moves for this position
local moves = get_generated_moves()

-- Create the result item
local item = {
    cgp = cgp,
    moves = moves,
    tiles_remaining = tiles_remaining
}

print(json.encode(item))