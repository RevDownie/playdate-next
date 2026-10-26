import argparse
import json
import shutil
import os

"""
Convert the Tiled format into binary data and image format for PD sprite sheets
"""
SCALE_DIVIDER = 4

DROP_SIZES = {'small': 0, 'large': 1}

def find_layer(json_data, layer_type, name=None):
    for layer in json_data['layers']:
        if layer['type'] == layer_type and (name is None or layer['name'] == name):
            return layer
    return None

def create_tile_id_map(json_data):
    """
    Map the used tiles into a 1-based ID for assignment to playdate spritesheets
    """
    id_map = {}
    next_id = 1
    grid = find_layer(json_data, 'tilelayer')['data']
    for tid in grid:
        if tid > 0 and tid not in id_map:
            id_map[tid] = next_id
            next_id += 1
    return id_map


def find_drop_points(json_data, layer):
    """
    Point objects on the 'drops' object layer, named 'small' or 'large', as (cell index, size id).
    Each must sit on an empty (floor) cell
    """
    drops_layer = find_layer(json_data, 'objectgroup', 'drops')
    if drops_layer is None:
        return []
    drops = []
    for obj in drops_layer['objects']:
        col = int(obj['x'] // json_data['tilewidth'])
        row = int(obj['y'] // json_data['tileheight'])
        if not (0 <= col < layer['width'] and 0 <= row < layer['height']):
            raise ValueError(f"Drop point {obj['id']} is outside the map")
        idx = row * layer['width'] + col
        if layer['data'][idx] > 0:
            raise ValueError(f"Drop point {obj['id']} is on a blocked cell ({col}, {row})")
        if obj['name'] not in DROP_SIZES:
            raise ValueError(f"Drop point {obj['id']} must be named one of {list(DROP_SIZES)}")
        drops.append((idx, DROP_SIZES[obj['name']]))
    if len(drops) > 255:
        raise ValueError("Too many drop points")
    return drops

def convert_lvl_json(lvl_name, json_data, tile_id_map):
    """
    Output format: header (u8 width, u8 height, u8 cell width px, u8 cell height px), u8 drop point count,
    then per drop point u16 cell index, u8 size (0 small, 1 large),
    then the occupied tiles until the end of the file as u16 cell index, u8 sprite id
    """
    with open(f"levels/{lvl_name}.bin", "wb") as of:
        layer = find_layer(json_data, 'tilelayer')
        of.write(layer['width'].to_bytes(1, byteorder='little'))
        of.write(layer['height'].to_bytes(1, byteorder='little'))
        of.write((json_data['tilewidth'] // SCALE_DIVIDER).to_bytes(1, byteorder='little'))
        of.write((json_data['tileheight'] // SCALE_DIVIDER).to_bytes(1, byteorder='little'))

        drops = find_drop_points(json_data, layer)
        of.write(len(drops).to_bytes(1, byteorder='little'))
        for idx, size in drops:
            of.write(idx.to_bytes(2, byteorder='little'))
            of.write(size.to_bytes(1, byteorder='little'))

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

