import subprocess
import argparse
import os

"""
Simple script for running Imagemagick on source images to convert them to 1 bit images for Playdate
"""


"""
Run imagemagick on all the files in the given folder
"""
def convertCharacterSprites(imagemagick, dir_name):
    for f in os.listdir(dir_name):
        input_path = os.path.join(dir_name, f)
        output_path = os.path.join('images', f)
        cmds = [imagemagick, input_path, "-transparent", "red", "-background", "none", "-colorspace", "gray", "-ordered-dither", "h6x6a", "-gravity", "center", "-extent", "648x648", "-resize", "48x48", output_path]
        p = subprocess.Popen(cmds, stdout=subprocess.PIPE, shell=True)
        p.communicate()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(prog = 'Convert Raw Images', description = 'Convert pngs to 1bit images for Playdate')
    parser.add_argument('imagemagick') 

    args = parser.parse_args() 

    # Characters
    convertCharacterSprites(args.imagemagick, "raw-images\\Hero1")
    convertCharacterSprites(args.imagemagick, "raw-images\\Enemy1")

    # BGs
    cmds = [args.imagemagick, "raw-images\\bg.png", "-colorspace", "gray", "-ordered-dither", "h4x4a", "images\\bg.png"]
    p = subprocess.Popen(cmds, stdout=subprocess.PIPE, shell=True)
    p.communicate()

    # Launchers
    cmds = [args.imagemagick, "raw-images\\card.png", "-colorspace", "gray", "images\\card.png"]
    p = subprocess.Popen(cmds, stdout=subprocess.PIPE, shell=True)
    p.communicate()
