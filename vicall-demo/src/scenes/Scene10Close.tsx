import React from 'react';
import {AbsoluteFill, Img, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {ChannelVariant, getChannelCopy} from '../channelCopy';
import {SceneContainer} from '../components/SceneContainer';
import {hasStaticAsset, staticAsset} from '../lib/static';
import {colors, fonts} from '../theme';

export const Scene10Close: React.FC<{
	durationInFrames?: number;
	channelVariant?: ChannelVariant;
}> = ({durationInFrames, channelVariant = 'esafe'}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const channelCopy = getChannelCopy(channelVariant);
	const progress = spring({fps, frame: Math.max(0, frame - 10), config: {damping: 16, stiffness: 120}, durationInFrames: 20});
	const logo = staticAsset('vicall-logo.png');

	return (
		<SceneContainer variant="fade" durationInFrames={durationInFrames}>
			<AbsoluteFill
				style={{
					background: 'linear-gradient(180deg, #fcfdff 0%, #f3f7fd 100%)',
					alignItems: 'center',
					justifyContent: 'center',
					gap: 18,
				}}
			>
				<div
					style={{
						transform: `scale(${interpolate(progress, [0, 1], [0.85, 1])})`,
						opacity: progress,
						display: 'flex',
						flexDirection: 'column',
						alignItems: 'center',
					}}
				>
					{logo && hasStaticAsset('vicall-logo.png') ? (
						<Img
							src={logo}
							style={{
								width: 180,
								height: 180,
								objectFit: 'contain',
								borderRadius: 36,
								filter: 'drop-shadow(0 20px 48px rgba(12,32,72,0.10))',
							}}
						/>
					) : (
						<div
							style={{
								width: 180,
								height: 180,
								borderRadius: 36,
								background: 'linear-gradient(135deg, rgba(77,124,255,0.12), rgba(0,230,118,0.08))',
								border: `1px solid ${colors.borderLight}`,
								boxShadow: '0 20px 48px rgba(12,32,72,0.10)',
								display: 'flex',
								alignItems: 'center',
								justifyContent: 'center',
								color: colors.text,
								fontFamily: fonts.headline,
								fontSize: 42,
								fontWeight: 800,
							}}
						>
							V
						</div>
					)}
					<div
						style={{
							marginTop: 26,
							fontFamily: fonts.headline,
							fontSize: 38,
							fontWeight: 800,
							color: colors.text,
							textAlign: 'center',
						}}
					>
						{channelCopy.closeHeadline}
					</div>
					<div
						style={{
							marginTop: 12,
							fontFamily: fonts.body,
							fontSize: 22,
							color: colors.muted,
							textAlign: 'center',
							maxWidth: 820,
						}}
					>
						{channelCopy.closeSubline}
					</div>
				</div>
			</AbsoluteFill>
		</SceneContainer>
	);
};
