from PIL import Image, ImageEnhance
from rich.console import Console
from rich.panel import Panel
from rich.text import Text
from rich.align import Align
from rich.color import Color
import os

console = Console()

def image_to_colored_ascii(image_path, width=120):
    """이미지를 컬러풀한 ASCII 아트로 변환 (고선명도)"""
    try:
        # 이미지 열기
        img = Image.open(image_path).convert('RGB')
        
        # 사이즈 조정 (해상도 증가)
        original_width, original_height = img.size
        aspect_ratio = original_height / original_width
        new_height = int(aspect_ratio * width * 0.5)  # 비율 조정으로 더 선명하게
        img = img.resize((width, new_height))  # 리샘플링
        
        # 대비 강화
        enhancer = ImageEnhance.Contrast(img)
        img = enhancer.enhance(1.2)  # 대비 20% 증가
        
        # 더욱 세밀한 ASCII 문자셋 (정확한 밀도 순서 - 밝은 부분은 흰색 블럭)
        chars = " .:;+*%S#▒░▓▏▎▍▌▋▊▉█"
        
        # RGB 픽셀 데이터 가져오기
        pixels = list(img.getdata())
        
        # ASCII 문자와 색상으로 변환
        ascii_lines = []
        for y in range(new_height):
            line = Text()
            for x in range(width):
                if y * width + x < len(pixels):
                    r, g, b = pixels[y * width + x]
                    
                    # 더 정확한 밝기 계산 (인간 시각 가중치 적용)
                    brightness = 0.299 * r + 0.587 * g + 0.114 * b
                    
                    # 비선형 매핑으로 대비 강화
                    normalized = brightness / 255.0
                    enhanced = normalized ** 0.8  # 감마 보정
                    
                    char_index = int(enhanced * (len(chars) - 1))
                    char_index = min(char_index, len(chars) - 1)
                    char = chars[char_index]
                    
                    # RGB 색상 적용 (채도 약간 증가)
                    enhanced_r = min(255, int(r * 1.1))
                    enhanced_g = min(255, int(g * 1.1))
                    enhanced_b = min(255, int(b * 1.1))
                    
                    line.append(char, style=f"rgb({enhanced_r},{enhanced_g},{enhanced_b})")
                else:
                    line.append(" ")
            ascii_lines.append(line)
        
        return ascii_lines
    
    except Exception as e:
        console.print(f"[red]오류 발생: {e}[/red]")
        return None

def display_ascii_art(image_path):
    """ASCII 아트를 예쁘게 출력"""
    console.print()
    console.print("[bold cyan]🎨 이미지를 ASCII 아트로 변환 중...[/bold cyan]")
    
    # ASCII 아트 생성
    ascii_lines = image_to_colored_ascii(image_path)
    
    if ascii_lines:
        # 파일명 추출
        filename = os.path.basename(image_path)
        
        # 제목 생성
        title = Text.assemble(
            ("✨ ", "yellow"),
            (f"ASCII Art: {filename}", "bold magenta"),
            (" ✨", "yellow")
        )
        
        # ASCII 아트를 패널에 담기
        ascii_content = Text()
        for line in ascii_lines:
            ascii_content.append(line)
            ascii_content.append("\n")
        
        # 중앙 정렬된 패널로 출력
        panel = Panel(
            Align.center(ascii_content),
            title=title,
            border_style="bright_blue",
            padding=(1, 2)
        )
        
        console.print(panel)
        console.print()
        console.print("[green]✅ 변환 완료![/green]")
        console.print(f"[dim]원본 크기: {Image.open(image_path).size}[/dim]")
        
        # 저장 옵션 제공
        save_option = console.input("\n[yellow]ASCII 아트를 파일로 저장하시겠습니까? (y/n): [/yellow]")
        if save_option.lower() == 'y':
            save_ascii_to_file(ascii_lines, filename)

def save_ascii_to_file(ascii_lines, original_filename):
    """ASCII 아트를 파일로 저장"""
    output_filename = f"ascii_{original_filename.split('.')[0]}.txt"
    
    try:
        with open(output_filename, 'w', encoding='utf-8') as f:
            for line in ascii_lines:
                # 색상 정보 제거하고 순수 텍스트만 저장
                plain_text = line.plain
                f.write(plain_text + '\n')
        
        console.print(f"[green]✅ {output_filename} 파일로 저장되었습니다![/green]")
    except Exception as e:
        console.print(f"[red]저장 중 오류 발생: {e}[/red]")

if __name__ == "__main__":
    image_path = "./assets/Shiftup.jpg"
    display_ascii_art(image_path)