import argparse
import json
import shutil
import os

"""
Convert the Tiled format into binary data and image format for PD sprite sheets
"""
SCALE_DIVIDER = 4

def create_tile_id_map(json_data):
    """
    Map the used tiles into a 1-based ID for assignment to playdate spritesheets
    """
    id_map = {}
    next_id = 1
    grid = json_data['layers'][0]['data']
    for tid in grid:
        if tid > 0 and tid not in id_map:
            id_map[tid] = next_id
            next_id += 1
    return id_map


def convert_lvl_json(lvl_name, json_data, tile_id_map):
    """
    Output format just writes out occupied tiles as idx,sprite,idx,sprite
    """
    with open(f"levels/{lvl_name}.bin", "wb") as of:
        layer = json_data['layers'][0]
        of.write(layer['width'].to_bytes(1, byteorder='little'))
        of.write(layer['height'].to_bytes(1, byteorder='little'))
        of.write((json_data['tilewidth'] // SCALE_DIVIDER).to_bytes(1, byteorder='little'))
        of.write((json_data['tileheight'] // SCALE_DIVIDER).to_bytes(1, byteorder='little'))

        grid = layer['data']
        for i, tid in enumerate(grid):
            if tid > 0:
                of.write(i.to_bytes(2, byteorder='little'))
                of.write(tile_id_map[tid].to_bytes(1, byteorder='little')) 

def copy_tile_images(lvl_name, json_data, tile_id_map):
    """
    Read the data and copy the tile images, renaming based on the mapped name
    """
    tiles = json_data['tiles']
    for tile in tiles:
        id = tile['id'] + 1
        if id in id_map:
            img = tile['image']
            outimg = f"raw-levels/{lvl_name}-table-{tile_id_map[id]}.png"
            shutil.copyfile("map-tiles/" + img, outimg)



if __name__ == "__main__":
    parser = argparse.ArgumentParser(prog = 'Convert Tiled', description = 'Convert Tiled data into Playdate data') 
    args = parser.parse_args() 

    if os.path.isdir('levels'):
        shutil.rmtree('levels')
    os.mkdir('levels')

    if os.path.isdir('raw-levels'):
        shutil.rmtree('raw-levels')
    os.mkdir('raw-levels')

    level_names = ["lvl1"]

    for level_name in level_names:
        with open(f'map-tiles/{level_name}.json', 'r') as f:
            data = json.load(f)
            id_map = create_tile_id_map(data)
            convert_lvl_json(level_name, data, id_map)

            tilemap_file = data['tilesets'][0]['source'].replace('tsx', 'json')
            with open(f'map-tiles/{tilemap_file}', 'r') as tf:
                data = json.load(tf)
                copy_tile_images(level_name, data, id_map)

