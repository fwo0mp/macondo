#!/usr/bin/env lua

-- Dataset generation script for Macondo
-- Generates game states at different stages (early/mid/late) with top 100 moves
-- Usage: script scripts/lua/generate_dataset.lua <num_items> [early_ratio] [mid_ratio] [late_ratio]

local macondo = require("macondo")
local json = require("json")

-- Parse command line arguments (args is a single string, not an array)
if not args then
    print("Usage: script scripts/lua/generate_dataset.lua <num_items> [early_ratio] [mid_ratio] [late_ratio]")
    print("Example: script scripts/lua/generate_dataset.lua 1000 0.33 0.33 0.34")
    print("Generates 1000 items with even split between game stages")
    print("")
    print("This script works by:")
    print("1. Starting new games and simulating AI turns")
    print("2. Capturing positions at target game stages")
    print("3. Generating top 100 moves for each position")
    return
end

local num_items = tonumber(args[1])
if not num_items or num_items <= 0 then
    print("Error: num_items must be a positive number")
    return
end

-- Parse ratios with defaults to even split
local early_ratio = 0.33
local mid_ratio = 0.33
local late_ratio = 0.34

-- Validate ratios
if math.abs(early_ratio + mid_ratio + late_ratio - 1.0) > 0.001 then
    print("Error: Ratios must sum to 1.0")
    return
end

print("Generating " .. num_items .. " dataset items:")
print("  Early game: " .. (early_ratio * 100) .. "%")
print("  Mid game: " .. (mid_ratio * 100) .. "%") 
print("  Late game: " .. (late_ratio * 100) .. "%")

-- Calculate items per stage
local early_items = math.floor(num_items * early_ratio)
local mid_items = math.floor(num_items * mid_ratio)
local late_items = num_items - early_items - mid_items

-- Game stage definitions based on tiles remaining in bag
local EARLY_GAME_MIN_TILES = 70
local MID_GAME_MIN_TILES = 20
local LATE_GAME_MIN_TILES = 0

-- Helper function to get tiles remaining from game state
function get_tiles_remaining()
    local game_state = macondo.gamestate()
    local unseenStr = game_state:match("(%d+) in the bag")
    return tonumber(unseenStr)
end

-- Helper function to extract moves from gen output
function get_generated_moves()
    -- Generate moves and get the current game state
    macondo.gen("100 simple")
    
    -- Parse moves from the game state output
    local moves = {}
    local lines = {}
    for line in game_state:gmatch("[^\n]+") do
        table.insert(lines, line)
    end
    
    -- Look for move listings in the game state
    local parsing_moves = false
    for i, line in ipairs(lines) do
        if line:match("Generated moves:") or line:match("Moves:") then
            parsing_moves = true
        elseif parsing_moves and line:match("^%s*%d+") then
            -- Parse move line: "1. PLAY SCORE EQUITY"
            local num, play, score, equity = line:match("^%s*(%d+)%.%s*(%S+%s*%S*)%s+(%d+)%s+([-+%d%.]+)")
            if play and score and equity then
                table.insert(moves, {
                    rank = tonumber(num),
                    play = play,
                    score = tonumber(score),
                    equity = tonumber(equity)
                })
            end
        end
    end
    
    return moves
end

-- Function to simulate a game until reaching target tiles remaining
function simulate_to_target_stage(target_min_tiles, target_max_tiles)
    local max_attempts = 3
    local attempt = 0
    
    while attempt < max_attempts do
        attempt = attempt + 1
        
        -- Start a new game
        macondo.new()
        
        -- Play AI turns until we reach the target stage
        local tiles_remaining = 100 -- Start with full bag approximately
        
        while true do
            tiles_remaining = get_tiles_remaining()
            
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
            -- macondo.commit_ai()
            macondo.commit_hasty()
        end
    end
    
    return nil, nil -- Failed to generate valid position
end

-- Function to generate dataset items for a specific stage
function generate_items_for_stage(stage_name, target_count, target_min_tiles, target_max_tiles)
    local items = {}
    local generated = 0
    
    print("Generating " .. target_count .. " " .. stage_name .. " game items...")
    print("  Target tiles remaining: " .. target_min_tiles .. " to " .. target_max_tiles)
    
    while generated < target_count do
        local tiles_remaining, cgp = simulate_to_target_stage(target_min_tiles, target_max_tiles)
        local moves = get_generated_moves()
        
        local item = {
            cgp = cgp,
            moves = moves,
            stage = stage_name,
            tiles_remaining = tiles_remaining,
            generated_at = os.time()
        }
        
        table.insert(items, item)
        -- Save this single item immediately
        write_game_results({item})
        
        generated = generated + 1
    end
    
    if generated < target_count then
        print("  Warning: Only generated " .. generated .. "/" .. target_count .. " " .. stage_name .. " items")
    end
    
    return items
end

-- Initialize random seed
math.randomseed(os.time())

-- Generate dataset items
local dataset = {}
macondo.set("lexicon NWL23")

-- Generate early game items (70+ tiles remaining)
local early_items_list = generate_items_for_stage("early", early_items, EARLY_GAME_MIN_TILES, 100)
for _, item in ipairs(early_items_list) do
    table.insert(dataset, item)
end

-- Generate mid game items (20-69 tiles remaining)
local mid_items_list = generate_items_for_stage("mid", mid_items, MID_GAME_MIN_TILES, EARLY_GAME_MIN_TILES - 1)
for _, item in ipairs(mid_items_list) do
    table.insert(dataset, item)
end

-- Generate late game items (0-19 tiles remaining)
local late_items_list = generate_items_for_stage("late", late_items, LATE_GAME_MIN_TILES, MID_GAME_MIN_TILES - 1)
for _, item in ipairs(late_items_list) do
    table.insert(dataset, item)
end

-- Save dataset to file
function write_game_results(dataset)
    local filename = "/Users/brendon/src/macondo/scrabble_dataset.json"
    local file = io.open(filename, "a+") -- Open in append mode
    if file then
        -- If file is empty, start array, otherwise add comma first
        file:seek("end")
        local size = file:seek()
        if size == 0 then
            file:write("[\n")
        else
            file:seek("end", -2) -- Move before final ]
            file:write(",\n")
        end
        
        -- Write the new items
        file:write(json.encode(dataset))
        file:write("\n]")
        file:close()
        print("\nDataset appended to " .. filename)
        print("Generated " .. #dataset .. " out of " .. num_items .. " requested items")
    else
        print("\nError: Could not write to file " .. filename)
    end
end

-- Print summary statistics
local stage_counts = {early = 0, mid = 0, late = 0}
for _, item in ipairs(dataset) do
    stage_counts[item.stage] = stage_counts[item.stage] + 1
end

print("\nSummary:")
print("  Early game: " .. stage_counts.early .. " items")
print("  Mid game: " .. stage_counts.mid .. " items")
print("  Late game: " .. stage_counts.late .. " items")
print("  Total: " .. #dataset .. " items")

print("\nDataset structure:")
print("  Each item contains:")
print("    - cgp: Game state in CGP format")
print("    - moves: Array of top moves with rank, play, score, equity")
print("    - stage: Game stage (early/mid/late)")
print("    - tiles_remaining: Number of tiles left in bag")
print("    - generated_at: Unix timestamp")